#include "llama.h"
#include <CommonCrypto/CommonDigest.h>
#include <algorithm>
#include <array>
#include <csignal>
#include <filesystem>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <memory>
#include <nlohmann/json.hpp>
#include <sstream>
#include <stdexcept>
#include <string>
#include <sys/stat.h>
#include <thread>
#include <unistd.h>
#include <vector>

using nlohmann::json;
namespace {
volatile std::sig_atomic_t cancelled = 0;
constexpr auto modelSHA =
    "3b41ebe2502cbd03e811d5d16b022f5ab551eda58d62597d152f89535003c634";
constexpr auto modelName = "S1-mini by Superwhisper";
constexpr auto systemPrompt = "You are a text normalizer for speech-to-text "
                              "transcripts. The input begins "
                              "with a control line specifying the styling, "
                              "structure, and context settings; "
                              "clean the transcript to match those settings "
                              "and output only the cleaned text.";

struct Failure : std::runtime_error {
  std::string code;
  Failure(std::string value, const char *message)
      : std::runtime_error(message), code(std::move(value)) {}
};
void onSignal(int) { cancelled = 1; }
void checkCancellation() {
  if (cancelled)
    throw Failure("cancelled", "Cleanup was cancelled.");
}

// Pin the public release instead of accidentally executing another Qwen model.
void verifyModel(const std::string &path) {
  std::ifstream file(path, std::ios::binary);
  if (!file)
    throw Failure("model_missing",
                  "The S1-mini model file could not be opened.");
  CC_SHA256_CTX state;
  CC_SHA256_Init(&state);
  std::array<char, 65536> buffer{};
  while (file.read(buffer.data(), buffer.size()) || file.gcount()) {
    checkCancellation();
    CC_SHA256_Update(&state, buffer.data(),
                     static_cast<CC_LONG>(file.gcount()));
  }
  if (!file.eof())
    throw Failure("model_read_failed", "The S1-mini model could not be read.");
  std::array<unsigned char, CC_SHA256_DIGEST_LENGTH> digest{};
  CC_SHA256_Final(digest.data(), &state);
  std::ostringstream hex;
  for (auto byte : digest)
    hex << std::hex << std::setw(2) << std::setfill('0')
        << static_cast<int>(byte);
  if (hex.str() != modelSHA)
    throw Failure("model_checksum_mismatch",
                  "Select the official S1-mini Q4_K_M release. Its checksum "
                  "did not match.");
}

std::vector<llama_token> tokenize(const llama_vocab *vocab,
                                  const std::string &text, bool special) {
  if (text.empty())
    return {};
  const int count =
      -llama_tokenize(vocab, text.data(), static_cast<int>(text.size()),
                      nullptr, 0, false, special);
  if (count <= 0)
    throw Failure("tokenization_failed", "The input could not be tokenized.");
  std::vector<llama_token> result(count);
  const int actual =
      llama_tokenize(vocab, text.data(), static_cast<int>(text.size()),
                     result.data(), count, false, special);
  if (actual < 0)
    throw Failure("tokenization_failed", "The input could not be tokenized.");
  result.resize(actual);
  return result;
}

std::string choice(const json &input, const char *key, const char *fallback,
                   std::initializer_list<const char *> allowed) {
  if (input.contains(key) && !input.at(key).is_string())
    throw Failure("invalid_input", "Cleanup settings must be strings.");
  const std::string value = input.value(key, std::string(fallback));
  if (std::find(allowed.begin(), allowed.end(), value) == allowed.end())
    throw Failure("invalid_settings",
                  "The requested S1-mini setting is unsupported.");
  return value;
}

json normalize(const std::string &path, const json &input) {
  if (!input.is_object() || !input.contains("transcript") ||
      !input.at("transcript").is_string())
    throw Failure("invalid_input", "Input must contain a transcript string.");
  const auto transcript = input.at("transcript").get<std::string>();
  if (transcript.size() > 64000)
    throw Failure("input_too_long",
                  "Split the transcript into smaller sections before cleanup.");
  if (transcript.find('\0') != std::string::npos)
    throw Failure("invalid_input", "Transcript contains a null character.");
  const auto style = choice(input, "styling", "semi-formal",
                            {"casual", "semi-casual", "semi-formal", "formal"});
  const auto structure =
      choice(input, "structure", "prose", {"prose", "lists"});
  const auto context =
      choice(input, "context", "general", {"general", "email"});
  verifyModel(path);
  llama_log_set([](ggml_log_level, const char *, void *) {}, nullptr);
  llama_backend_init();
  auto params = llama_model_default_params();
  params.n_gpu_layers = 99;
  params.progress_callback = [](float, void *) { return !cancelled; };
  std::unique_ptr<llama_model, decltype(&llama_model_free)> model(
      llama_model_load_from_file(path.c_str(), params), llama_model_free);
  checkCancellation();
  if (!model)
    throw Failure("model_load_failed",
                  "S1-mini could not be loaded on this Mac.");
  const auto *vocab = llama_model_get_vocab(model.get());
  // Transcript special-token strings remain ordinary text, never chat
  // delimiters.
  auto content = tokenize(vocab, transcript, false);
  if (content.size() > 1000)
    throw Failure("input_too_long",
                  "S1-mini accepts at most 1000 transcript tokens per request. "
                  "Split this transcript before cleanup.");
  auto tokens = tokenize(
      vocab,
      std::string("<|im_start|>system\n") + systemPrompt +
          "<|im_end|>\n<|im_start|>user\n[Styling: " + style +
          "] [Structure: " + structure + "] [Context: " + context + "]\n",
      true);
  tokens.insert(tokens.end(), content.begin(), content.end());
  const auto suffix = tokenize(
      vocab, "<|im_end|>\n<|im_start|>assistant\n<think>\n\n</think>\n\n",
      true);
  tokens.insert(tokens.end(), suffix.begin(), suffix.end());
  const int budget = static_cast<int>((content.size() * 13 + 9) / 10 + 32);
  auto cp = llama_context_default_params();
  cp.n_ctx = static_cast<uint32_t>(tokens.size() + budget + 8);
  cp.n_batch = static_cast<uint32_t>(tokens.size());
  cp.n_threads = static_cast<int32_t>(
      std::max(1u, std::min(8u, std::thread::hardware_concurrency())));
  cp.n_threads_batch = cp.n_threads;
  cp.abort_callback = [](void *) { return cancelled != 0; };
  std::unique_ptr<llama_context, decltype(&llama_free)> ctx(
      llama_init_from_model(model.get(), cp), llama_free);
  checkCancellation();
  if (!ctx)
    throw Failure("context_failed",
                  "S1-mini could not allocate its inference context.");
  std::unique_ptr<llama_sampler, decltype(&llama_sampler_free)> sampler(
      llama_sampler_init_greedy(), llama_sampler_free);
  auto batch =
      llama_batch_get_one(tokens.data(), static_cast<int32_t>(tokens.size()));
  std::string output;
  bool complete = false;
  int generated = 0;
  for (int i = 0; i <= budget; ++i) {
    checkCancellation();
    const int result = llama_decode(ctx.get(), batch);
    checkCancellation();
    if (result != 0)
      throw Failure("decode_failed", "S1-mini inference failed.");
    auto token = llama_sampler_sample(sampler.get(), ctx.get(), -1);
    if (llama_vocab_is_eog(vocab, token)) {
      complete = true;
      break;
    }
    if (i == budget)
      break;
    std::array<char, 256> piece{};
    const int length =
        llama_token_to_piece(vocab, token, piece.data(), piece.size(), 0, true);
    if (length < 0)
      throw Failure("invalid_output", "S1-mini emitted an unsupported token.");
    output.append(piece.data(), length);
    ++generated;
    // Decode immediately while the local token storage is alive.
    tokens.assign(1, token);
    batch = llama_batch_get_one(tokens.data(), 1);
  }
  if (!complete)
    throw Failure("output_truncated", "S1-mini reached its output limit. The "
                                      "raw transcript is still available.");
  if (output.find("<|") != std::string::npos ||
      output.find("<think>") != std::string::npos ||
      output.find("</think>") != std::string::npos)
    throw Failure(
        "invalid_output",
        "S1-mini returned model control text instead of a transcript.");
  const auto first = output.find_first_not_of(" \t\r\n");
  output = first == std::string::npos
               ? ""
               : output.substr(first,
                               output.find_last_not_of(" \t\r\n") - first + 1);
  // Validate UTF-8 before constructing a successful response.
  try {
    static_cast<void>(json(output).dump());
  } catch (const json::exception &) {
    throw Failure("invalid_output", "S1-mini returned invalid text encoding.");
  }
  return {{"status", output.empty() ? "empty" : "success"},
          {"text", output},
          {"model", modelName},
          {"inputTokens", content.size()},
          {"outputTokens", generated}};
}

// Atomic replacement prevents the app from consuming a partial JSON result.
void writeResult(const std::string &path, const json &result) {
  const std::string serialized = result.dump();
  const auto temporary = path + ".partial-" + std::to_string(getpid());
  std::ofstream file(temporary, std::ios::binary | std::ios::trunc);
  file << serialized;
  file.close();
  if (!file) {
    std::filesystem::remove(temporary);
    throw std::runtime_error("Cannot write cleanup result.");
  }
  std::filesystem::rename(temporary, path);
}
} // namespace

int main(int argc, char **argv) {
  umask(0077);
  std::signal(SIGTERM, onSignal);
  std::signal(SIGINT, onSignal);
  std::string model, input, output;
  for (int i = 1; i + 1 < argc; i += 2) {
    const std::string key = argv[i];
    if (key == "--model")
      model = argv[i + 1];
    else if (key == "--input")
      input = argv[i + 1];
    else if (key == "--output")
      output = argv[i + 1];
    else {
      std::cerr << "Unknown argument.\n";
      return 1;
    }
  }
  if (argc != 7 || model.empty() || input.empty() || output.empty()) {
    std::cerr << "Usage: S1MiniHelper --model MODEL.gguf --input request.json "
                 "--output result.json\n";
    return 1;
  }
  json result;
  int exitCode = 0;
  try {
    if (std::filesystem::file_size(input) > 262144)
      throw Failure("invalid_input", "Cleanup request exceeds its size limit.");
    std::ifstream stream(input);
    if (!stream)
      throw Failure("invalid_input", "Cleanup input could not be opened.");
    json request;
    stream >> request;
    result = normalize(model, request);
    checkCancellation();
  } catch (const Failure &error) {
    exitCode = error.code == "cancelled" ? 130 : 1;
    result = {{"status", exitCode == 130 ? "cancelled" : "error"},
              {"text", ""},
              {"errorCode", error.code},
              {"error", error.what()}};
  } catch (const std::exception &) {
    // Parser exceptions may include transcript fragments; never expose them.
    exitCode = 1;
    result = {
        {"status", "error"},
        {"text", ""},
        {"errorCode", "invalid_request"},
        {"error", "The cleanup request or response could not be processed."}};
  }
  result["model"] = modelName;
  if (!result.contains("inputTokens"))
    result["inputTokens"] = 0;
  if (!result.contains("outputTokens"))
    result["outputTokens"] = 0;
  try {
    writeResult(output, result);
  } catch (const std::exception &) {
    std::cerr << "Could not save cleanup result.\n";
    return 1;
  }
  return exitCode;
}
