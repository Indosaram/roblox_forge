// Minimal first-party newline-delimited JSON emission helpers. This helper only
// produces JSON events; its commands arrive as a key=value request file plus
// single-token stdin lines, so no JSON parser is needed here.
#pragma once

#include <windows.h>

#include <cstdint>
#include <cstdio>
#include <string>
#include <string_view>
#include <vector>

namespace qualityav {

inline std::string WideToUtf8(std::wstring_view value) {
  if (value.empty()) return {};
  const int needed = ::WideCharToMultiByte(CP_UTF8, 0, value.data(), static_cast<int>(value.size()),
                                           nullptr, 0, nullptr, nullptr);
  if (needed <= 0) return {};
  std::string out(static_cast<size_t>(needed), '\0');
  ::WideCharToMultiByte(CP_UTF8, 0, value.data(), static_cast<int>(value.size()), out.data(), needed,
                        nullptr, nullptr);
  return out;
}

inline std::string JsonEscape(std::string_view value) {
  std::string out;
  out.reserve(value.size() + 8);
  for (const unsigned char ch : value) {
    switch (ch) {
      case '"': out += "\\\""; break;
      case '\\': out += "\\\\"; break;
      case '\b': out += "\\b"; break;
      case '\f': out += "\\f"; break;
      case '\n': out += "\\n"; break;
      case '\r': out += "\\r"; break;
      case '\t': out += "\\t"; break;
      default:
        if (ch < 0x20) {
          static constexpr char kHex[] = "0123456789abcdef";
          out += "\\u00";
          out += kHex[(ch >> 4) & 0xF];
          out += kHex[ch & 0xF];
        } else {
          out += static_cast<char>(ch);
        }
    }
  }
  return out;
}

// Sequential object builder. Build() is the only way to obtain the text, so a
// half-emitted object can never leak into the protocol stream.
class JsonObject {
 public:
  JsonObject& Str(std::string_view key, std::string_view value) {
    Key(key);
    body_ += '"';
    body_ += JsonEscape(value);
    body_ += '"';
    return *this;
  }
  JsonObject& Int(std::string_view key, long long value) {
    Key(key);
    body_ += std::to_string(value);
    return *this;
  }
  JsonObject& Uint(std::string_view key, unsigned long long value) {
    Key(key);
    body_ += std::to_string(value);
    return *this;
  }
  JsonObject& Num(std::string_view key, double value) {
    Key(key);
    char buffer[32];
    std::snprintf(buffer, sizeof(buffer), "%.17g", value);
    body_ += buffer;
    return *this;
  }
  JsonObject& Bool(std::string_view key, bool value) {
    Key(key);
    body_ += value ? "true" : "false";
    return *this;
  }
  // Embeds an already-serialized JSON value (nested object/array).
  JsonObject& Raw(std::string_view key, std::string_view json) {
    Key(key);
    body_.append(json.data(), json.size());
    return *this;
  }

  std::string Build() const {
    return '{' + body_ + '}';
  }

 private:
  void Key(std::string_view key) {
    if (!first_) body_ += ',';
    first_ = false;
    body_ += '"';
    body_ += JsonEscape(key);
    body_ += "\":";
  }

  std::string body_;
  bool first_ = true;
};

inline std::string JsonStringArray(const std::vector<std::string>& items) {
  std::string out = "[";
  bool first = true;
  for (const std::string& item : items) {
    if (!first) out += ',';
    first = false;
    out += '"';
    out += JsonEscape(item);
    out += '"';
  }
  out += ']';
  return out;
}

}  // namespace qualityav
