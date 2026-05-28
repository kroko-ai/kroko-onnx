#ifndef KROKO_KEYGEN_H_
#define KROKO_KEYGEN_H_

#ifndef ASIO_STANDALONE
#define ASIO_STANDALONE
#endif
#include "websocketpp/config/asio_client.hpp"
#include "websocketpp/client.hpp"

#include <iostream>
#include <string>
#include <vector>
#include <chrono>
#include <thread>
#include <regex>

#include "sherpa-onnx/csrc/njson.hpp"

typedef websocketpp::client<websocketpp::config::asio_tls_client> wsclient;
typedef websocketpp::lib::shared_ptr<asio::ssl::context> context_ptr;
using json = nlohmann::json;

struct Feature {
    std::string name;
    std::string value;
};

class LicenseClient {
public:
    wsclient c;

    // Public license info
    bool allowed = false;
    int total_seconds = 0;
    int remaining_seconds = 0;
    int max_connections = 0;
    int offline_timeout = 0;
    int report_interval = 0;
    std::string password;
    bool expirable = false;
    std::string expires_at;
    std::vector<Feature> features;
    std::string error_message;
    bool is_finish = false;

    LicenseClient() {
        c.init_asio();

        c.clear_access_channels(websocketpp::log::alevel::all);
        c.clear_error_channels(websocketpp::log::elevel::all);

        // TLS setup (now using standalone Asio)
        c.set_tls_init_handler([](websocketpp::connection_hdl) -> context_ptr {
            context_ptr ctx = websocketpp::lib::make_shared<asio::ssl::context>(
                asio::ssl::context::tlsv12);
            ctx->set_options(asio::ssl::context::default_workarounds |
                             asio::ssl::context::no_sslv2 |
                             asio::ssl::context::single_dh_use);
            return ctx;
        });

        // Message handler
        c.set_message_handler([this](websocketpp::connection_hdl hdl_in, wsclient::message_ptr msg) {
            hdl = hdl_in; // store for later use
            try {
                auto j = json::parse(msg->get_payload());

                if (j.contains("allowed") && !waiting_for_usage_response) {
                    allowed = j["allowed"].get<bool>();
                    if (!allowed) {
                        error_message = j.value("error", "Unknown error");
                        std::cerr << "❌ License not allowed: " << error_message << std::endl;
                        is_finish = true;
                        return;
                    }

                    total_seconds     = j.value("total_seconds", 0);
                    remaining_seconds = j.value("remaining_seconds", 0);
                    max_connections   = j.value("max_connections", 0);
                    offline_timeout   = j.value("offline_timeout", 0);
                    report_interval   = j.value("report_interval", 0);
                    password          = j.value("password", "");
                    expirable         = j.value("expirable", false);
                    expires_at        = j.value("expires_at", "");

                    features.clear();
                    if (j.contains("features") && j["features"].is_array()) {
                        for (const auto& f : j["features"]) {
                            features.push_back({f.value("name", ""), f.value("value", "")});
                        }
                    }

                    std::cout << "✅ License accepted. Remaining seconds: " << remaining_seconds << std::endl;
                    is_finish = true;
                    return;
                }

                // Handle usage report response
                if (waiting_for_usage_response) {
                    waiting_for_usage_response = false;
                    allowed = j["allowed"].get<bool>();
                    if (!allowed) {
                        error_message = j.value("error", "Unknown error");
                        std::cerr << "❌ License not allowed: " << error_message << std::endl;
                        is_finish = true;
                        return;
                    }

                    std::string err = j.value("error", "");
                    if (!err.empty() && err != "no") {
                        error_message = err;
                        std::cerr << "❗ Usage report error: " << err << std::endl;
                        return;
                    }

                    remaining_seconds = j.value("remaining_seconds", remaining_seconds);
                    std::cout << "⏱️ Remaining seconds updated: " << remaining_seconds << std::endl;
                }

            } catch (const std::exception& e) {
                std::cerr << "❌ JSON parse error: " << e.what() << std::endl;
            }
        });

        c.set_open_handler([this](websocketpp::connection_hdl hdl_in) {
            std::cout << "🔌 Connected to license server." << std::endl;
            hdl = hdl_in;
            is_connected = true;
            last_online_time = std::chrono::steady_clock::now();
        });

        c.set_close_handler([this](websocketpp::connection_hdl) {
            std::cout << "🔒 Connection closed." << std::endl;
            is_connected = false;
            last_online_time = std::chrono::steady_clock::now();
        });

        c.set_fail_handler([this](websocketpp::connection_hdl) {
            std::cerr << "❌ Connection failed." << std::endl;
            is_connected = false;
        });
    }

    void call(const std::string& server_name,
              const std::string& licenseKey,
              const std::string& modelIdReq,
              const std::string& instanceId,
              const std::string& referralcode = "") {
        std::string uri = "wss://" + server_name + "/ws/v1/" +
                          licenseKey + "/" + modelIdReq;
        if(referralcode.length()) {
            uri += "?referralcode=" + referralcode;
        }

        last_online_time = std::chrono::steady_clock::now();

        while (true) {
            websocketpp::lib::error_code ec;
            wsclient::connection_ptr con = c.get_connection(uri, ec);
            if (ec) {
                std::cerr << "❗ Failed to create connection: " << ec.message() << std::endl;
                std::this_thread::sleep_for(std::chrono::seconds(3));
                check_offline_timeout();
                continue;
            }

            c.connect(con);
            c.run();  // blocking
            c.reset();

            if (!is_connected) {
                std::cerr << "🔁 Retrying connection in 3s..." << std::endl;
                std::this_thread::sleep_for(std::chrono::seconds(3));
                check_offline_timeout();
            }
        }
    }

    bool send_usage_report(int seconds_used) {
        if (!allowed) {
            std::cerr << "⛔ Cannot send usage: license not allowed." << std::endl;
            return false;
        }

        if (!hdl.lock()) {
            std::cerr << "❌ No active WebSocket connection." << std::endl;
            return false;
        }

        json report = { {"seconds_used", seconds_used} };

        websocketpp::lib::error_code ec;
        c.send(hdl, report.dump(), websocketpp::frame::opcode::text, ec);
        if (ec) {
            std::cerr << "❌ Failed to send usage report: " << ec.message() << std::endl;
            return false;
        }

        waiting_for_usage_response = true;
        return true;
    }

    void check_offline_timeout() {
        if (offline_timeout == 0) return;

        auto now = std::chrono::steady_clock::now();
        auto offline_seconds = std::chrono::duration_cast<std::chrono::seconds>(now - last_online_time).count();

        if (offline_seconds > offline_timeout) {
            std::cerr << "❌ Offline timeout exceeded (" << offline_timeout << "s). Exiting." << std::endl;
            std::exit(1);
        }
    }

private:
    websocketpp::connection_hdl hdl;
    bool waiting_for_usage_response = false;
    std::chrono::steady_clock::time_point last_online_time;
    bool is_connected = false;
};

class LicenseState {
public:
    static LicenseClient& getInstance() {
        static LicenseClient instance;
        return instance;
    }

    LicenseState() = delete;
    LicenseState(const LicenseState&) = delete;
    LicenseState& operator=(const LicenseState&) = delete;
};

#ifdef KROKO_LICENSE
class BanafoLicense {
public:
  static BanafoLicense& getInstance(const std::string& key,
                                    const std::string& modelIdReq,
                                    const std::string& referralcode = "") {
    static BanafoLicense instance(key, modelIdReq, referralcode);
    return instance;
  }

  BanafoLicense(const std::string& key,
                const std::string& modelIdReq,
                const std::string& referralcode = "") {
    mThread = std::thread([=]() {
      auto& client = LicenseState::getInstance();
      client.call("license.kroko.ai", key, modelIdReq, "none", referralcode);
    });

    auto& client = LicenseState::getInstance();
    while (!client.is_finish) {
      std::this_thread::sleep_for(std::chrono::seconds(1));
    }
    mActivated = client.allowed;
    mActivationFinished = true;
    if (!mActivated) {
      std::cerr << "❌ License activation failed: " << client.error_message << std::endl;
    }
  }

  ~BanafoLicense() {
    if (mThread.joinable()) {
      mThread.join();
    }
  }

  std::atomic<bool> mActivationFinished{false};
  bool mActivated{false};
  std::string id;

private:
  std::thread mThread;

  // Disable copy and assignment to enforce singleton
  BanafoLicense(const BanafoLicense&) = delete;
  BanafoLicense& operator=(const BanafoLicense&) = delete;
};
#endif

#endif
