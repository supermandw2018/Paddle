/* Copyright (c) 2021 PaddlePaddle Authors. All Rights Reserved.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License. */

#include <time.h>

#include <random>
#include <vector>

#include "paddle/fluid/operators/fused/fused_dropout_test.h"
#include "paddle/fluid/operators/fused/fused_residual_dropout_bias.h"

namespace framework = paddle::framework;
namespace platform = paddle::platform;

/**
 * @brief the unittest of fusedresidualdropoutbias
 * 1. random input data
 * 2. add bias, call paddle dropout op, add residual, and get the base result
 * 3. call FusedResidualDropoutBias function get fused result
 * 4. compare ther base result and fused result
 */

template <typename T>
struct TestFusedResidualDropoutBias {
  uint32_t rows;
  uint32_t cols;
  uint64_t seed;
  float dropout_prob;
  bool is_upscale_in_train;
  bool is_test;  // default false,  Set to true for inference only
  bool has_bias = true;
  framework::Tensor src, residual, bias, out, mask;
  framework::Tensor dsrc, dbias;

  std::vector<T> src_vec, residual_vec, bias_vec;
  std::vector<T> correct_out, correct_dsrc, correct_dbias;
  std::vector<uint8_t> correct_mask;

  platform::CUDAPlace place;
  platform::CUDADeviceContext *ctx;

  TestFusedResidualDropoutBias() {
    rows = 32;
    cols = 32;
    seed = 0;
    dropout_prob = 0.0;
    is_upscale_in_train = false;
    is_test = false;
    has_bias = true;
    platform::DeviceContextPool &pool = platform::DeviceContextPool::Instance();
    auto device_ctx = pool.Get(place);
    ctx = reinterpret_cast<platform::CUDADeviceContext *>(device_ctx);
  }

  TestFusedResidualDropoutBias(int rows_, int cols_, uint64_t seed_ = 0,
                               float dropout_prob_ = 0.0,
                               bool is_upscale_in_train_ = false,
                               bool is_test_ = false) {
    rows = rows_;
    cols = cols_;
    seed = seed_;
    dropout_prob = dropout_prob_;
    is_upscale_in_train = is_upscale_in_train_;
    is_test = is_test_;
    has_bias = true;
    platform::DeviceContextPool &pool = platform::DeviceContextPool::Instance();
    auto device_ctx = pool.Get(place);
    ctx = reinterpret_cast<platform::CUDADeviceContext *>(device_ctx);
  }

  ~TestFusedResidualDropoutBias() {}

  void SetUp() {
    const int n = rows * cols;
    correct_out.resize(n);
    correct_mask.resize(n);
    correct_dsrc.resize(n);
    correct_dbias.resize(cols);

    src_vec.resize(n);
    residual_vec.resize(n);
    bias_vec.resize(cols);
    std::default_random_engine random(time(NULL));
    std::uniform_real_distribution<float> dis(0.0, 1.0);

    for (int i = 0; i < rows; i++) {
      for (int j = 0; j < cols; j++) {
        src_vec[i * cols + j] = static_cast<T>(dis(random));
        residual_vec[i * cols + j] = static_cast<T>(dis(random));
        if (i == 0) {
          bias_vec[j] = dis(random);
        }
      }
    }

    framework::TensorFromVector<T>(src_vec, *ctx, &src);
    src.Resize({rows, cols});
    framework::TensorFromVector<T>(residual_vec, *ctx, &residual);
    residual.Resize({rows, cols});
    if (has_bias) {
      framework::TensorFromVector<T>(bias_vec, *ctx, &bias);
      bias.Resize({cols});
    }

    {
      out.Resize({rows, cols});
      out.mutable_data<T>(place);
      mask.Resize({rows, cols});
      mask.mutable_data<uint8_t>(place);
      dsrc.Resize({rows, cols});
      dsrc.mutable_data<T>(place);

      if (has_bias) {
        dbias.Resize({cols});
        dbias.mutable_data<T>(place);
      }
    }
  }

  void BaseForward() {
    std::vector<T> out1(rows * cols), out2(rows * cols);
    if (has_bias) {
      // add bias
      for (int i = 0; i < rows; i++) {
        for (int j = 0; j < cols; j++) {
          out1[i * cols + j] = src_vec[i * cols + j] + bias_vec[j];
        }
      }
      // call dropout
      Dropout<T>(out1, src.dims(), &out2, &correct_mask, *ctx, seed,
                 dropout_prob, is_upscale_in_train, is_test);
    } else {
      Dropout<T>(src_vec, src.dims(), &out2, &correct_mask, *ctx, seed,
                 dropout_prob, is_upscale_in_train, is_test);
    }
    ctx->Wait();
    // add residual
    for (int i = 0; i < rows; i++) {
      for (int j = 0; j < cols; j++) {
        correct_out[i * cols + j] =
            residual_vec[i * cols + j] + out2[i * cols + j];
      }
    }
  }

  void BaseBackward() {
    DropoutGrad<T>(&correct_dsrc, src.dims(), correct_out, correct_mask, *ctx,
                   dropout_prob, is_upscale_in_train);
    // calc dbias
    memset(&correct_dbias[0], 0, cols * sizeof(T));
    for (int i = 0; i < rows; i++) {
      for (int j = 0; j < cols; j++) {
        correct_dbias[j] += correct_out[i * cols + j];
      }
    }
  }

  void FusedForward() {
    const int VecSize = MAX_CACHE_BYTES / sizeof(T);
    auto config = paddle::operators::Get1DBlocksAnd2DGrids(
        *ctx, (uint64_t)rows, (uint64_t)cols, VecSize);
    const int increment = ((cols - 1) / (config.thread_per_block.x *
                                         config.block_per_grid.x * VecSize) +
                           1) *
                          VecSize;

    T *bias_ptr = nullptr;
    if (has_bias) {
      bias_ptr = bias.data<T>();
    }
    paddle::operators::LaunchResidualDropoutBias<T, uint8_t>(
        rows, cols, increment, seed, dropout_prob, is_test, is_upscale_in_train,
        src.data<T>(), residual.data<T>(), bias_ptr, mask.data<uint8_t>(),
        out.data<T>(), *ctx);
    ctx->Wait();
  }

  void FusedBackward() {
    if (is_test) {
      return;
    }

    T *bias_ptr = nullptr;
    if (has_bias) {
      bias_ptr = dbias.data<T>();
    }
    paddle::operators::LaunchResidualDropoutBiasGrad<T, uint8_t>(
        out.data<T>(), mask.data<uint8_t>(), dropout_prob, is_upscale_in_train,
        rows, cols, dsrc.data<T>(), bias_ptr, *ctx);
  }

  void Run() {
    SetUp();
    BaseForward();
    FusedForward();
    BaseBackward();
    FusedBackward();
  }

  void CheckOut(const T diff) {
    const int n = rows * cols;
    std::vector<T> _out(n);
    std::vector<uint8_t> _mask(n);
    framework::TensorToVector(out, *ctx, &_out);
    if (!is_test) {
      framework::TensorToVector<uint8_t>(mask, *ctx, &_mask);
    }
    ctx->Wait();

    for (int i = 0; i < n; i++) {
      EXPECT_LT(std::abs(_out[i] - correct_out[i]), diff);
      if (!is_test) EXPECT_EQ(_mask[i], correct_mask[i]);
    }
  }

  void CheckGrad(const T diff) {
    if (is_test) {
      return;
    }

    const int n = rows * cols;

    std::vector<T> _dsrc(n);
    framework::TensorToVector(dsrc, *ctx, &_dsrc);

    for (int i = 0; i < n; i++) {
      EXPECT_LT(std::abs(_dsrc[i] - correct_dsrc[i]), diff);
    }

    if (has_bias) {
      std::vector<T> _dbias(cols);
      framework::TensorToVector(dbias, *ctx, &_dbias);
      ctx->Wait();
      for (int i = 0; i < cols; i++) {
        EXPECT_LT(std::abs(_dbias[i] - correct_dbias[i]), diff);
      }
    }
  }
};

// test the shape and bias
template <typename T>
static void BaseTest(const bool is_fp16 = false) {
  const int rows = 16;
  std::vector<int> cols_list = {16, 17};
  bool has_bias[2] = {true, false};
  T default_diff = static_cast<T>(1e-5);
  if (is_fp16) {
    default_diff = static_cast<T>(1e-2);
  }
  for (int i = 0; i < cols_list.size(); i++) {
    for (int j = 0; j < 2; j++) {
      TestFusedResidualDropoutBias<T> test(rows, cols_list[i]);
      test.has_bias = has_bias[j];
      test.Run();
      test.CheckOut(default_diff);
      if (!is_fp16) {
        test.CheckGrad(default_diff);
      }
    }
  }
}

TEST(FusedDropout, GPUFusedResidualDropoutBias) { BaseTest<float>(); }

TEST(FusedDropout, GPUFusedResidualDropoutBiasDouble) { BaseTest<double>(); }

// test fp16, For inference, check_grad is not required. ref: testdropout_op.py
TEST(FusedDropout, GPUFusedResidualDropoutBiasFp16) {
  BaseTest<platform::float16>(true);
}

TEST(FusedDropout, GPUFusedResidualDropoutBias2) {
  const int rows = 16;
  const int cols = 16;
  TestFusedResidualDropoutBias<float> test(rows, cols, 0, 1.0, false, false);
  test.Run();
  test.CheckOut(static_cast<float>(1e-5));
  test.CheckGrad(static_cast<float>(1e-5));
}

TEST(FusedDropout, GPUFusedResidualDropoutBias3) {
  const int rows = 16;
  const int cols = 16;
  TestFusedResidualDropoutBias<float> test(rows, cols, 0, 1.0, true, false);
  test.Run();
  test.CheckOut(static_cast<float>(1e-5));
  test.CheckGrad(static_cast<float>(1e-5));
}

TEST(FusedDropout, GPUFusedResidualDropoutBias4) {
  const int rows = 16;
  const int cols = 16;
  TestFusedResidualDropoutBias<float> test(rows, cols, 0, 0.35, true, true);
  test.Run();
  test.CheckOut(static_cast<float>(1e-5));
  test.CheckGrad(static_cast<float>(1e-5));
}

TEST(FusedDropout, GPUFusedResidualDropoutBias5) {
  const int rows = 16;
  const int cols = 16;
  TestFusedResidualDropoutBias<float> test(rows, cols, 125, 0.0, false, false);
  test.Run();
  test.CheckOut(static_cast<float>(1e-5));
  test.CheckGrad(static_cast<float>(1e-5));
}

// test large shape
TEST(FusedDropout, GPUFusedResidualDropoutBias6) {
  const int rows = 256;
  const int cols = 4096;
  TestFusedResidualDropoutBias<float> test(rows, cols);
  test.Run();
  test.CheckOut(static_cast<float>(1e-5));
  test.CheckGrad(static_cast<float>(1e-3));
}
