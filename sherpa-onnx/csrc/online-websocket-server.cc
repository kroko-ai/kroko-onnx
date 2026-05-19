// sherpa-onnx/csrc/online-websocket-server.cc
//
// Copyright (c)  2022-2023  Xiaomi Corporation

#include <chrono>
#include <thread>

#include "asio.hpp"
#include "sherpa-onnx/csrc/macros.h"
#include "sherpa-onnx/csrc/online-websocket-server-impl.h"
#include "sherpa-onnx/csrc/parse-options.h"
#include "sherpa-onnx/csrc/httplib.h"

const char* banafo_help = R"(

Automatic speech recognition using websocket.
Usage:

./kroko-onnx-online-websocket-server --help
./kroko-onnx-online-websocket-server\
  --port=6006\
  --model=model.data
  
Thank you for using Kroko! 🎉

This project is open source and can be freely used under the open source license.
For users who need commercial features, support, or access to paid models, we also offer a commercial license.

📦 Downloading Free Models

You can download them from:

👉 https://huggingface.co/Banafo/Kroko-ASR

🔑 Getting a Trial License

Go to https://app.kroko.ai/
Register or Log in to your account.
In the sidebar, click On-premise.
Click the GET trial button.
You will receive a license key.
Once you have the key, run the executable with the activation command:

./kroko-onnx-online-websocket-server --key=YOUR_LICENSE_KEY --model=DOWNLOADED_KROKO_MODEL

📦 Downloading Paid Models

Paid models are available only for commercial license users.
You can download them from:

👉 https://app.kroko.ai/on-premise

After downloading, place the models in the appropriate directory (for example: models/).
)";

#ifdef KROKO_LICENSE 
void* http_thread(void* ptr) {
  try {
    httplib::Server svr;

    svr.Get("/health", [](const httplib::Request&, httplib::Response& res) {
      res.set_content("", "text/plain");
    });

    svr.Get("/metrics", [](const httplib::Request&, httplib::Response& res) {
      char buf[100];
      std::time_t t = std::time(nullptr);
      std::tm tm = *std::gmtime(&t); // Convert to GMT/UTC time
      std::strftime(buf, sizeof(buf), "%a, %d %b %Y %H:%M:%S GMT", &tm);
      std::string date = std::string(buf);
      res.set_header("Date", date);
      std::string msg = "# HELP decoder_connections Amount of active connections\n# TYPE decoder_connections gauge\ndecoder_connections " + std::to_string(sherpa_onnx::total_connections) + "\n";
      res.set_content(msg, "text/plain; version=0.0.4");
    });

    svr.Get("/ready", [](const httplib::Request&, httplib::Response& res) {
      if(sherpa_onnx::num_max_connections == 0 || sherpa_onnx::total_connections < sherpa_onnx::num_max_connections) {
        res.set_content("", "text/plain");
      }
      else {
        res.set_content("", "text/plain");
        res.status = 503;
      }
    });

    std::this_thread::sleep_for(std::chrono::seconds(5));
    svr.listen("0.0.0.0", *(int32_t*)ptr);
  } catch(std::exception& e)
  {
      std::cerr << e.what();
      exit(1);
  }
  return NULL;
}
#endif

static const std::string kUsageMessage = "Automatic speech recognition using websocket.\n"
        "Usage:\n\n"
        "./onnx-online-websocket-server --help\n\n"
        "./onnx-online-websocket-server \\\n"
        "  --port=6006 \\\n"
        "  --num-work-threads=5 \\\n"
        "  --loop-interval-ms=10\n";

int32_t main(int32_t argc, char *argv[]) {
#ifndef KROKO_MODEL  
  sherpa_onnx::ParseOptions po(kUsageMessage.c_str());
#else
  sherpa_onnx::ParseOptions po(banafo_help);
#endif

  sherpa_onnx::OnlineWebsocketServerConfig config;

  // the server will listen on this port
  int32_t port = 6006;
  int32_t metrics_port = 0;
  int32_t num_max_conn = 0;

  // size of the thread pool for handling network connections
  int32_t num_io_threads = 1;

  // size of the thread pool for neural network computation and decoding
  int32_t num_work_threads = 3;

  std::string key;

  po.Register("num-io-threads", &num_io_threads,
              "Thread pool size for network connections.");

  po.Register("num-work-threads", &num_work_threads,
              "Thread pool size for for neural network "
              "computation and decoding.");

  po.Register("port", &port, "The port on which the server will listen.");

  po.Register("metrics_port", &metrics_port, "The port on which the server will listen for metrics API. Requires Scaling feature license.");

  config.Register(&po);

  if (argc == 1) {
    po.PrintUsage();
    exit(EXIT_FAILURE);
  }

  po.Read(argc, argv);

  if (po.NumArgs() != 0) {
    SHERPA_ONNX_LOGE("Unrecognized positional arguments!");
    po.PrintUsage();
    exit(EXIT_FAILURE);
  }

  if(port == metrics_port) {
    SHERPA_ONNX_LOGE("Both port and metrics_port can't be the same!");
    exit(EXIT_FAILURE);
  }

  config.Validate();

#ifdef KROKO_LICENSE
  // std::thread instead of pthread_t — portable across glibc / MSVC,
  // and the original `http_th = pthread_create(&http_th, ...)` was a
  // type-confusion bug anyway (stored the int return code into the
  // pthread_t slot, then joined to "0"). Scoped to KROKO_LICENSE
  // because http_thread itself is gated behind the same flag.
  std::thread http_th;
#endif
  asio::io_context io_conn;  // for network connections
  asio::io_context io_work;  // for neural network and decoding

  sherpa_onnx::OnlineWebsocketServer server(io_conn, io_work, config);
  server.Run(port);

  SHERPA_ONNX_LOGE("Started!");
  SHERPA_ONNX_LOGE("Listening on: %d", port);
  SHERPA_ONNX_LOGE("Number of work threads: %d", num_work_threads);

#ifdef KROKO_LICENSE
  if(metrics_port > 0) {
    http_th = std::thread(http_thread, &metrics_port);
  }
#endif

  // give some work to do for the io_work pool
  auto work_guard = asio::make_work_guard(io_work);

  std::vector<std::thread> io_threads;

  // decrement since the main thread is also used for network communications
  for (int32_t i = 0; i < num_io_threads - 1; ++i) {
    io_threads.emplace_back([&io_conn]() { io_conn.run(); });
  }

  std::vector<std::thread> work_threads;
  for (int32_t i = 0; i < num_work_threads; ++i) {
    work_threads.emplace_back([&io_work]() { io_work.run(); });
  }

  io_conn.run();

  for (auto &t : io_threads) {
    t.join();
  }

  for (auto &t : work_threads) {
    t.join();
  }

#ifdef KROKO_LICENSE
  if(metrics_port > 0 && http_th.joinable()) {
    http_th.join();
  }
#endif

  return 0;
}
