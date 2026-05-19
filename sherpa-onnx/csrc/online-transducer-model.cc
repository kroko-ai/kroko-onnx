// sherpa-onnx/csrc/online-transducer-model.cc
//
// Copyright (c)  2023  Xiaomi Corporation
// Copyright (c)  2023  Pingfeng Luo
#include "sherpa-onnx/csrc/online-transducer-model.h"

#if __ANDROID_API__ >= 9
#include "android/asset_manager.h"
#include "android/asset_manager_jni.h"
#endif

#if __OHOS__
#include "rawfile/raw_file_manager.h"
#endif

#include <algorithm>
#include <chrono>
#include <memory>
#include <sstream>
#include <string>
#include <thread>

#include "sherpa-onnx/csrc/file-utils.h"
#include "sherpa-onnx/csrc/macros.h"
#include "sherpa-onnx/csrc/online-conformer-transducer-model.h"
#include "sherpa-onnx/csrc/online-ebranchformer-transducer-model.h"
#include "sherpa-onnx/csrc/online-lstm-transducer-model.h"
#include "sherpa-onnx/csrc/online-zipformer-transducer-model.h"
#include "sherpa-onnx/csrc/online-zipformer2-transducer-model.h"
#include "sherpa-onnx/csrc/onnx-utils.h"
#include "sherpa-onnx/csrc/ModelData.h"
#include "sherpa-onnx/csrc/license.h"

namespace {

enum class ModelType : std::uint8_t {
  kConformer,
  kEbranchformer,
  kLstm,
  kZipformer,
  kZipformer2,
  kUnknown,
};

}  // namespace

namespace sherpa_onnx {

#ifdef KROKO_MODEL
#ifdef KROKO_LICENSE
std::atomic<uint64_t> total_duration = 0;
std::atomic<bool> license_status = false;
std::atomic<uint64_t> total_connections = 0;
std::atomic<int32_t> num_max_connections = 0;

void* check_license(void* ptr) {
    std::string* arr = (std::string*)ptr;
    LicenseClient& client = LicenseState::getInstance();

    while (true) {
        std::this_thread::sleep_for(std::chrono::seconds(client.report_interval));
        uint64_t duration = sherpa_onnx::total_duration / 1000;

        // Ensure we don’t overuse the license
        if (duration > client.remaining_seconds) {
            duration = client.remaining_seconds;
        }

        bool ok = client.send_usage_report(duration);

        if (!ok) {
            std::cerr << "❌ License reporting failed: " << client.error_message << std::endl;
        } else {
            sherpa_onnx::license_status = true;
        }

        if(!client.allowed) {
          sherpa_onnx::license_status = false;
          exit(1);
        }

        sherpa_onnx::total_duration = 0;
    }

    return nullptr;
}
#endif

void BanafoLoadModel(const OnlineModelConfig &config) {
#ifdef KROKO_LICENSE
    auto& model = ModelData::getInstance();
    if (!model.loadHeader(config.model_path)) {
      std::cerr << "Failed to load model header." << std::endl;
      exit(1);
    }

    if(model.getHeaderValue("free") == "false") {
      auto& banafo = BanafoLicense::getInstance(config.key, model.getHeaderValue("id"), config.referralcode);

      while(!banafo.mActivationFinished)
      {
        std::this_thread::sleep_for(std::chrono::seconds(1));
      }
      if(!banafo.mActivated) {
        exit(1);
      }

      sherpa_onnx::license_status = true;
      std::thread(check_license, nullptr).detach();

      auto& client = LicenseState::getInstance();
    
      if (!model.decryptPayload(client.password)) {
        std::cerr << "Failed to decrypt payload." << std::endl;
        exit(1);
      }
    }
    else {
      sherpa_onnx::license_status = true;
      if (!model.loadPayload()) {
        std::cerr << "Failed to load the payload." << std::endl;
        exit(1);
      }
    }
#else
    auto& model = ModelData::getInstance();
    if (!model.loadHeader(config.model_path)) {
        std::cerr << "Failed to load model header." << std::endl;
        exit(1);
    }
    if (!model.loadPayload()) {
      std::cerr << "Failed to load the payload." << std::endl;
      exit(1);
    }
#endif
}
#endif

static ModelType GetModelType(char *model_data, size_t model_data_length,
                              bool debug) {
  Ort::Env env(ORT_LOGGING_LEVEL_ERROR);
  Ort::SessionOptions sess_opts;
  sess_opts.SetIntraOpNumThreads(1);
  sess_opts.SetInterOpNumThreads(1);

  auto sess = std::make_unique<Ort::Session>(env, model_data, model_data_length,
                                             sess_opts);

  Ort::ModelMetadata meta_data = sess->GetModelMetadata();
  if (debug) {
    std::ostringstream os;
    PrintModelMetadata(os, meta_data);
#if __OHOS__
    SHERPA_ONNX_LOGE("%{public}s", os.str().c_str());
#else
    SHERPA_ONNX_LOGE("%s", os.str().c_str());
#endif
  }

  Ort::AllocatorWithDefaultOptions allocator;
  auto model_type =
      LookupCustomModelMetaData(meta_data, "model_type", allocator);
  if (model_type.empty()) {
    SHERPA_ONNX_LOGE(
        "No model_type in the metadata!\n"
        "Please make sure you are using the latest export-onnx.py from icefall "
        "to export your transducer models");
    return ModelType::kUnknown;
  }

  if (model_type == "conformer") {
    return ModelType::kConformer;
  } else if (model_type == "ebranchformer") {
    return ModelType::kEbranchformer;
  } else if (model_type == "lstm") {
    return ModelType::kLstm;
  } else if (model_type == "zipformer") {
    return ModelType::kZipformer;
  } else if (model_type == "zipformer2") {
    return ModelType::kZipformer2;
  } else {
    SHERPA_ONNX_LOGE("Unsupported model_type: %s", model_type.c_str());
    return ModelType::kUnknown;
  }
}

std::unique_ptr<OnlineTransducerModel> OnlineTransducerModel::Create(
    const OnlineModelConfig &config) {
  // Runtime dispatch between Banafo (Kroko commercial .data) and the
  // standard sherpa-onnx file-based loader. Only invoke the Banafo
  // loader when a model_path was actually configured for this recognizer;
  // OSS configs (transducer.encoder/decoder/joiner) must NOT touch the
  // ModelData singleton, otherwise mixed Kroko+OSS deployments break.
  const bool use_banafo = !config.model_path.empty();
  if (use_banafo) {
    BanafoLoadModel(config);
    auto &model = ModelData::getInstance();
    const auto &model_type = model.getHeaderValue("type");
    if (model_type == "conformer") {
      return std::make_unique<OnlineConformerTransducerModel>(config);
    } else if (model_type == "ebranchformer") {
      return std::make_unique<OnlineEbranchformerTransducerModel>(config);
    } else if (model_type == "lstm") {
      return std::make_unique<OnlineLstmTransducerModel>(config);
    } else if (model_type == "zipformer") {
      return std::make_unique<OnlineZipformerTransducerModel>(config);
    } else if (model_type == "zipformer2") {
      return std::make_unique<OnlineZipformer2TransducerModel>(config);
    } else {
      SHERPA_ONNX_LOGE(
          "Invalid model_type from Banafo header: %s",
          model_type.c_str());
    }
  } else if (!config.model_type.empty()) {
    const auto &model_type = config.model_type;
    if (model_type == "conformer") {
      return std::make_unique<OnlineConformerTransducerModel>(config);
    } else if (model_type == "ebranchformer") {
      return std::make_unique<OnlineEbranchformerTransducerModel>(config);
    } else if (model_type == "lstm") {
      return std::make_unique<OnlineLstmTransducerModel>(config);
    } else if (model_type == "zipformer") {
      return std::make_unique<OnlineZipformerTransducerModel>(config);
    } else if (model_type == "zipformer2") {
      return std::make_unique<OnlineZipformer2TransducerModel>(config);
    } else {
      SHERPA_ONNX_LOGE(
          "Invalid model_type: %s. Trying to load the model to get its type",
          model_type.c_str());
    }
  }
  ModelType model_type = ModelType::kUnknown;

  {
    auto buffer = ReadFile(config.transducer.encoder);

    model_type = GetModelType(buffer.data(), buffer.size(), config.debug);
  }

  switch (model_type) {
    case ModelType::kConformer:
      return std::make_unique<OnlineConformerTransducerModel>(config);
    case ModelType::kEbranchformer:
      return std::make_unique<OnlineEbranchformerTransducerModel>(config);
    case ModelType::kLstm:
      return std::make_unique<OnlineLstmTransducerModel>(config);
    case ModelType::kZipformer:
      return std::make_unique<OnlineZipformerTransducerModel>(config);
    case ModelType::kZipformer2:
      return std::make_unique<OnlineZipformer2TransducerModel>(config);
    case ModelType::kUnknown:
      SHERPA_ONNX_LOGE("Unknown model type in online transducer!");
      return nullptr;
  }

  // unreachable code
  return nullptr;
}

Ort::Value OnlineTransducerModel::BuildDecoderInput(
    const std::vector<OnlineTransducerDecoderResult> &results) {
  int32_t batch_size = static_cast<int32_t>(results.size());
  int32_t context_size = ContextSize();
  std::array<int64_t, 2> shape{batch_size, context_size};
  Ort::Value decoder_input = Ort::Value::CreateTensor<int64_t>(
      Allocator(), shape.data(), shape.size());
  int64_t *p = decoder_input.GetTensorMutableData<int64_t>();

  for (const auto &r : results) {
    const int64_t *begin = r.tokens.data() + r.tokens.size() - context_size;
    const int64_t *end = r.tokens.data() + r.tokens.size();
    std::copy(begin, end, p);
    p += context_size;
  }
  return decoder_input;
}

Ort::Value OnlineTransducerModel::BuildDecoderInput(
    const std::vector<Hypothesis> &hyps) {
  int32_t batch_size = static_cast<int32_t>(hyps.size());
  int32_t context_size = ContextSize();
  std::array<int64_t, 2> shape{batch_size, context_size};
  Ort::Value decoder_input = Ort::Value::CreateTensor<int64_t>(
      Allocator(), shape.data(), shape.size());
  int64_t *p = decoder_input.GetTensorMutableData<int64_t>();

  for (const auto &h : hyps) {
    std::copy(h.ys.end() - context_size, h.ys.end(), p);
    p += context_size;
  }
  return decoder_input;
}

template <typename Manager>
std::unique_ptr<OnlineTransducerModel> OnlineTransducerModel::Create(
    Manager *mgr, const OnlineModelConfig &config) {
  // Runtime dispatch (see Create(config) above for the non-Manager path).
  if (!config.model_path.empty()) {
    BanafoLoadModel(config);
  }

  if (!config.model_type.empty()) {
    const auto &model_type = config.model_type;
    if (model_type == "conformer") {
      return std::make_unique<OnlineConformerTransducerModel>(mgr, config);
    } else if (model_type == "ebranchformer") {
      return std::make_unique<OnlineEbranchformerTransducerModel>(mgr, config);
    } else if (model_type == "lstm") {
      return std::make_unique<OnlineLstmTransducerModel>(mgr, config);
    } else if (model_type == "zipformer") {
      return std::make_unique<OnlineZipformerTransducerModel>(mgr, config);
    } else if (model_type == "zipformer2") {
      return std::make_unique<OnlineZipformer2TransducerModel>(mgr, config);
    } else {
      SHERPA_ONNX_LOGE(
          "Invalid model_type: %s. Trying to load the model to get its type",
          model_type.c_str());
    }
  }

  auto buffer = ReadFile(mgr, config.transducer.encoder);
  auto model_type = GetModelType(buffer.data(), buffer.size(), config.debug);

  switch (model_type) {
    case ModelType::kConformer:
      return std::make_unique<OnlineConformerTransducerModel>(mgr, config);
    case ModelType::kEbranchformer:
      return std::make_unique<OnlineEbranchformerTransducerModel>(mgr, config);
    case ModelType::kLstm:
      return std::make_unique<OnlineLstmTransducerModel>(mgr, config);
    case ModelType::kZipformer:
      return std::make_unique<OnlineZipformerTransducerModel>(mgr, config);
    case ModelType::kZipformer2:
      return std::make_unique<OnlineZipformer2TransducerModel>(mgr, config);
    case ModelType::kUnknown:
      SHERPA_ONNX_LOGE("Unknown model type in online transducer!");
      return nullptr;
  }

  // unreachable code
  return nullptr;
}

#if __ANDROID_API__ >= 9
template std::unique_ptr<OnlineTransducerModel> OnlineTransducerModel::Create(
    AAssetManager *mgr, const OnlineModelConfig &config);
#endif

#if __OHOS__
template std::unique_ptr<OnlineTransducerModel> OnlineTransducerModel::Create(
    NativeResourceManager *mgr, const OnlineModelConfig &config);
#endif

}  // namespace sherpa_onnx
