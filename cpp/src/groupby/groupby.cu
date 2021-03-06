/*
 * Copyright (c) 2019-2021, NVIDIA CORPORATION.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#include <cudf/column/column.hpp>
#include <cudf/column/column_factories.hpp>
#include <cudf/column/column_view.hpp>
#include <cudf/copying.hpp>
#include <cudf/detail/aggregation/aggregation.hpp>
#include <cudf/detail/gather.hpp>
#include <cudf/detail/groupby.hpp>
#include <cudf/detail/groupby/sort_helper.hpp>
#include <cudf/detail/nvtx/ranges.hpp>
#include <cudf/dictionary/dictionary_column_view.hpp>
#include <cudf/groupby.hpp>
#include <cudf/table/table.hpp>
#include <cudf/table/table_view.hpp>
#include <cudf/types.hpp>
#include <cudf/utilities/error.hpp>

#include <rmm/cuda_stream_view.hpp>

#include <thrust/copy.h>

#include <memory>
#include <utility>

namespace cudf {
namespace groupby {
// Constructor
groupby::groupby(table_view const& keys,
                 null_policy include_null_keys,
                 sorted keys_are_sorted,
                 std::vector<order> const& column_order,
                 std::vector<null_order> const& null_precedence)
  : _keys{keys},
    _include_null_keys{include_null_keys},
    _keys_are_sorted{keys_are_sorted},
    _column_order{column_order},
    _null_precedence{null_precedence}
{
}

// Select hash vs. sort groupby implementation
std::pair<std::unique_ptr<table>, std::vector<aggregation_result>> groupby::dispatch_aggregation(
  host_span<aggregation_request const> requests,
  rmm::cuda_stream_view stream,
  rmm::mr::device_memory_resource* mr)
{
  // If sort groupby has been called once on this groupby object, then
  // always use sort groupby from now on. Because once keys are sorted,
  // all the aggs that can be done by hash groupby are efficiently done by
  // sort groupby as well.
  // Only use hash groupby if the keys aren't sorted and all requests can be
  // satisfied with a hash implementation
  if (_keys_are_sorted == sorted::NO and not _helper and
      detail::hash::can_use_hash_groupby(_keys, requests)) {
    return detail::hash::groupby(_keys, requests, _include_null_keys, stream, mr);
  } else {
    return sort_aggregate(requests, stream, mr);
  }
}

// Destructor
// Needs to be in source file because sort_groupby_helper was forward declared
groupby::~groupby() = default;

namespace {
/// Make an empty table with appropriate types for requested aggs
auto empty_results(host_span<aggregation_request const> requests)
{
  std::vector<aggregation_result> empty_results;

  std::transform(
    requests.begin(), requests.end(), std::back_inserter(empty_results), [](auto const& request) {
      std::vector<std::unique_ptr<column>> results;

      std::transform(
        request.aggregations.begin(),
        request.aggregations.end(),
        std::back_inserter(results),
        [&request](auto const& agg) {
          return make_empty_column(cudf::detail::target_type(request.values.type(), agg->kind));
        });

      return aggregation_result{std::move(results)};
    });

  return empty_results;
}

/// Verifies the agg requested on the request's values is valid
void verify_valid_requests(host_span<aggregation_request const> requests)
{
  CUDF_EXPECTS(
    std::all_of(
      requests.begin(),
      requests.end(),
      [](auto const& request) {
        return std::all_of(
          request.aggregations.begin(), request.aggregations.end(), [&request](auto const& agg) {
            auto values_type = cudf::is_dictionary(request.values.type())
                                 ? cudf::dictionary_column_view(request.values).keys().type()
                                 : request.values.type();
            return cudf::detail::is_valid_aggregation(values_type, agg->kind);
          });
      }),
    "Invalid type/aggregation combination.");

// The aggregations listed in the lambda below will not work with a values column of type
// dictionary if this is compiled with nvcc/ptxas 10.2.
// https://nvbugswb.nvidia.com/NvBugs5/SWBug.aspx?bugid=3186317&cp=
#if (__CUDACC_VER_MAJOR__ == 10) and (__CUDACC_VER_MINOR__ == 2)
  CUDF_EXPECTS(
    std::all_of(
      requests.begin(),
      requests.end(),
      [](auto const& request) {
        return std::all_of(
          request.aggregations.begin(), request.aggregations.end(), [&request](auto const& agg) {
            return (!cudf::is_dictionary(request.values.type()) ||
                    !(agg->kind == aggregation::SUM or agg->kind == aggregation::MEAN or
                      agg->kind == aggregation::STD or agg->kind == aggregation::VARIANCE));
          });
      }),
    "dictionary type not supported for this aggregation");
#endif
}

}  // namespace

// Compute aggregation requests
std::pair<std::unique_ptr<table>, std::vector<aggregation_result>> groupby::aggregate(
  host_span<aggregation_request const> requests, rmm::mr::device_memory_resource* mr)
{
  CUDF_FUNC_RANGE();
  CUDF_EXPECTS(
    std::all_of(requests.begin(),
                requests.end(),
                [this](auto const& request) { return request.values.size() == _keys.num_rows(); }),
    "Size mismatch between request values and groupby keys.");

  verify_valid_requests(requests);

  if (_keys.num_rows() == 0) { return std::make_pair(empty_like(_keys), empty_results(requests)); }

  return dispatch_aggregation(requests, rmm::cuda_stream_default, mr);
}

// Compute scan requests
std::pair<std::unique_ptr<table>, std::vector<aggregation_result>> groupby::scan(
  host_span<aggregation_request const> requests, rmm::mr::device_memory_resource* mr)
{
  CUDF_FUNC_RANGE();
  CUDF_EXPECTS(
    std::all_of(requests.begin(),
                requests.end(),
                [this](auto const& request) { return request.values.size() == _keys.num_rows(); }),
    "Size mismatch between request values and groupby keys.");

  verify_valid_requests(requests);

  if (_keys.num_rows() == 0) { return std::make_pair(empty_like(_keys), empty_results(requests)); }

  return sort_scan(requests, rmm::cuda_stream_default, mr);
}

groupby::groups groupby::get_groups(table_view values, rmm::mr::device_memory_resource* mr)
{
  CUDF_FUNC_RANGE();
  auto grouped_keys = helper().sorted_keys(rmm::cuda_stream_default, mr);

  auto const& group_offsets = helper().group_offsets(rmm::cuda_stream_default);
  std::vector<size_type> group_offsets_vector(group_offsets.size());
  thrust::copy(thrust::device_pointer_cast(group_offsets.begin()),
               thrust::device_pointer_cast(group_offsets.end()),
               group_offsets_vector.begin());

  if (values.num_columns()) {
    auto grouped_values = cudf::detail::gather(values,
                                               helper().key_sort_order(rmm::cuda_stream_default),
                                               cudf::out_of_bounds_policy::DONT_CHECK,
                                               cudf::detail::negative_index_policy::NOT_ALLOWED,
                                               rmm::cuda_stream_default,
                                               mr);
    return groupby::groups{
      std::move(grouped_keys), std::move(group_offsets_vector), std::move(grouped_values)};
  } else {
    return groupby::groups{std::move(grouped_keys), std::move(group_offsets_vector)};
  }
}

// Get the sort helper object
detail::sort::sort_groupby_helper& groupby::helper()
{
  if (_helper) return *_helper;
  _helper = std::make_unique<detail::sort::sort_groupby_helper>(
    _keys, _include_null_keys, _keys_are_sorted);
  return *_helper;
};

}  // namespace groupby
}  // namespace cudf
