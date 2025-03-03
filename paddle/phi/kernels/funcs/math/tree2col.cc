// Copyright (c) 2024 PaddlePaddle Authors. All Rights Reserved.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

#include "paddle/phi/kernels/funcs/math/tree2col.h"

#include <deque>
#include <stack>

namespace phi {
namespace math {
std::vector<TreeNode> Tree2ColUtil::construct_patch(
    size_t root, int max_depth, const std::vector<std::vector<int>> &tr) {
  std::stack<TreeNode, std::deque<TreeNode>> stack;
  std::unordered_map<int, bool> visited;
  std::vector<TreeNode> patch;

  stack.emplace(root, 1, 1, 0);
  patch.emplace_back(root, 1, 1, 0);
  visited[static_cast<int>(root)] = true;

  while (!stack.empty()) {
    TreeNode &u = stack.top();
    bool end = true;
    size_t node = u.get_node(), sz = tr[node].size();
    visited[static_cast<int>(node)] = true;
    for (size_t i = 0; i < sz; i++) {
      size_t v = tr[node][i];
      if (!visited[static_cast<int>(v)] &&
          static_cast<int>(u.get_depth()) + 1 < max_depth) {
        visited[static_cast<int>(v)] = true;
        stack.emplace(v, i, sz, u.get_depth() + 1);
        patch.emplace_back(v, i + 1, sz, u.get_depth() + 1);
        end = false;
      }
    }
    if (end) {
      stack.pop();
    }
  }
  return patch;
}

void Tree2ColUtil::construct_tree(const phi::DenseTensor &EdgeSet,
                                  std::vector<std::vector<int>> *tr,
                                  size_t *node_count) {
  const auto &edge_set_dims = EdgeSet.dims();
  PADDLE_ENFORCE_EQ(edge_set_dims[1],
                    2,
                    phi::errors::InvalidArgument(
                        "The second dimension of the EdgeSet shall be 2, but "
                        "got %ld != 2. Please check the input value.",
                        edge_set_dims[1]));
  int64_t edge_count = EdgeSet.numel();

  const int *edge_data = EdgeSet.data<int>();

  for (int64_t i = 0; i < edge_count; i += 2) {
    int u = edge_data[i], v = edge_data[i + 1];
    if (u != 0 && v != 0) (*node_count)++;
  }
  (*node_count)++;

  tr->resize(static_cast<size_t>(*node_count + 1));

  for (int64_t i = 0; i < edge_count; i += 2) {
    int u = edge_data[i], v = edge_data[i + 1];
    if (u != 0 && v != 0) {
      tr->at(u).push_back(v);
    } else {
      break;
    }
  }
}

template <typename T>
class Tree2ColFunctor<phi::CPUContext, T> {
 public:
  void operator()(const phi::CPUContext &context,
                  const phi::DenseTensor &EdgeSet,
                  const phi::DenseTensor &node_features,
                  phi::DenseTensor *patch,
                  int max_depth) {
    std::vector<std::vector<int>> tr;
    const auto &feature_dims = node_features.dims();
    phi::funcs::SetConstant<phi::CPUContext, T> constant;
    int64_t feature_size = feature_dims[1];
    size_t patch_elem_size = 3 * static_cast<size_t>(feature_size);
    size_t node_count = 0, patch_count = 0, patch_size = 0;
    Tree2ColUtil::construct_tree(EdgeSet, &tr, &node_count);
    std::vector<std::vector<TreeNode>> processing_list;
    for (size_t u = 1; u <= node_count; u++) {
      std::vector<TreeNode> temp_patch =
          Tree2ColUtil::construct_patch(u, max_depth, tr);
      if (!temp_patch.empty()) {
        processing_list.emplace_back(temp_patch);
      }
    }
    patch_size = processing_list.size();

    patch->Resize({static_cast<int64_t>(patch_size),
                   static_cast<int64_t>(patch_elem_size)});
    T *patch_data = context.template Alloc<T>(patch);
    constant(context, patch, 0);
    const T *features = node_features.data<T>();

    for (auto &patch_item : processing_list) {
      size_t pointer_base = patch_count * patch_elem_size;
      for (auto &v : patch_item) {
        T eta_l = v.eta_l<T>(max_depth), eta_r = v.eta_r<T>(max_depth),
          eta_t = v.eta_t<T>(max_depth);
        size_t id = v.get_node() - 1;
        for (int i = 0; i < feature_size; i++) {
          patch_data[pointer_base + i * 3] +=
              eta_l * features[id * feature_size + i];
          patch_data[pointer_base + i * 3 + 1] +=
              eta_r * features[id * feature_size + i];
          patch_data[pointer_base + i * 3 + 2] +=
              eta_t * features[id * feature_size + i];
        }
      }
      patch_count++;
    }
    patch->Resize({static_cast<int64_t>(patch_count),
                   static_cast<int64_t>(patch_elem_size)});
  }
};
template <typename T>
class Col2TreeFunctor<phi::CPUContext, T> {
 public:
  void operator()(const phi::CPUContext &context,
                  const phi::DenseTensor &EdgeSet,
                  const phi::DenseTensor &out_grad,
                  phi::DenseTensor *in_grad,
                  int max_depth) {
    std::vector<std::vector<int>> tr;
    const auto &output_dims = out_grad.dims();
    phi::funcs::SetConstant<phi::CPUContext, T> constant;
    int64_t output_size = output_dims[1];
    size_t grad_elem_size = 3 * static_cast<size_t>(output_size);
    size_t node_count = 0, grad_count = 0;
    Tree2ColUtil::construct_tree(EdgeSet, &tr, &node_count);
    std::vector<std::vector<TreeNode>> processing_list;
    std::vector<std::vector<TreeNode>> grad_list;
    grad_list.resize(node_count);
    for (size_t u = 1; u <= node_count; u++) {
      std::vector<TreeNode> tmp =
          Tree2ColUtil::construct_patch(u, max_depth, tr);
      if (!tmp.empty()) {
        processing_list.push_back(tmp);
      }
    }
    for (size_t patch_id = 0; patch_id < processing_list.size(); patch_id++) {
      for (auto v : processing_list[patch_id]) {
        grad_list[v.get_node() - 1].push_back(v.change_node(patch_id + 1));
      }
    }
    in_grad->Resize({static_cast<int64_t>(node_count),
                     static_cast<int64_t>(grad_elem_size)});
    T *grad_data = context.template Alloc<T>(in_grad);

    constant(context, in_grad, 0);
    const T *out_g = out_grad.data<T>();
    for (auto &patch_item : grad_list) {
      size_t pointer_base = grad_count * grad_elem_size;
      for (auto &v : patch_item) {
        T eta_l = v.eta_l<T>(max_depth), eta_r = v.eta_r<T>(max_depth),
          eta_t = v.eta_t<T>(max_depth);
        size_t id = v.get_node() - 1;
        for (int i = 0; i < output_size; i++) {
          grad_data[pointer_base + i * 3] +=
              eta_l * out_g[id * output_size + i];
          grad_data[pointer_base + i * 3 + 1] +=
              eta_r * out_g[id * output_size + i];
          grad_data[pointer_base + i * 3 + 2] +=
              eta_t * out_g[id * output_size + i];
        }
      }
      grad_count++;
    }
  }
};

template class Tree2ColFunctor<phi::CPUContext, float>;
template class Tree2ColFunctor<phi::CPUContext, double>;
template class Col2TreeFunctor<phi::CPUContext, float>;
template class Col2TreeFunctor<phi::CPUContext, double>;
}  // namespace math
}  // namespace phi
