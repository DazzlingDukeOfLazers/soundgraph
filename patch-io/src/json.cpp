#include "json.h"

#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>

namespace soundgraph {
namespace json {
namespace {

class Parser {
public:
    Parser(const std::string& text) : text_(text) {}

    bool parse(Value& out) {
        skip_whitespace();
        if (!parse_value(out, 0)) {
            return false;
        }
        skip_whitespace();
        if (position_ != text_.size()) {
            return fail("unexpected trailing content");
        }
        return true;
    }

    const std::string& error() const { return error_; }

private:
    static constexpr int kMaxDepth = 64;

    bool fail(const std::string& message) {
        if (!error_.empty()) {
            return false;  // keep the innermost error
        }
        std::size_t line = 1;
        std::size_t column = 1;
        for (std::size_t i = 0; i < position_ && i < text_.size(); ++i) {
            if (text_[i] == '\n') {
                ++line;
                column = 1;
            } else {
                ++column;
            }
        }
        error_ = "line " + std::to_string(line) + ", column " + std::to_string(column) + ": " + message;
        return false;
    }

    void skip_whitespace() {
        while (position_ < text_.size()) {
            const char character = text_[position_];
            if (character == ' ' || character == '\t' || character == '\n' || character == '\r') {
                ++position_;
            } else {
                break;
            }
        }
    }

    bool at(char character) const {
        return position_ < text_.size() && text_[position_] == character;
    }

    bool literal(const char* text) {
        const std::size_t length = std::strlen(text);
        if (text_.compare(position_, length, text) != 0) {
            return false;
        }
        position_ += length;
        return true;
    }

    bool parse_value(Value& out, int depth) {
        if (depth > kMaxDepth) {
            return fail("nesting is too deep");
        }
        if (position_ >= text_.size()) {
            return fail("unexpected end of input");
        }

        const char character = text_[position_];
        switch (character) {
            case '{': return parse_object(out, depth);
            case '[': return parse_array(out, depth);
            case '"': {
                std::string value;
                if (!parse_string(value)) {
                    return false;
                }
                out = Value(std::move(value));
                return true;
            }
            case 't':
                if (!literal("true")) return fail("invalid literal");
                out = Value(true);
                return true;
            case 'f':
                if (!literal("false")) return fail("invalid literal");
                out = Value(false);
                return true;
            case 'n':
                if (!literal("null")) return fail("invalid literal");
                out = Value();
                return true;
            default:
                return parse_number(out);
        }
    }

    bool parse_object(Value& out, int depth) {
        ++position_;  // '{'
        out = Value::make_object();
        skip_whitespace();
        if (at('}')) {
            ++position_;
            return true;
        }
        for (;;) {
            skip_whitespace();
            std::string key;
            if (!parse_string(key)) {
                return fail("expected a property name");
            }
            skip_whitespace();
            if (!at(':')) {
                return fail("expected ':' after a property name");
            }
            ++position_;
            skip_whitespace();
            Value value;
            if (!parse_value(value, depth + 1)) {
                return false;
            }
            out.object().emplace_back(std::move(key), std::move(value));
            skip_whitespace();
            if (at(',')) {
                ++position_;
                continue;
            }
            if (at('}')) {
                ++position_;
                return true;
            }
            return fail("expected ',' or '}'");
        }
    }

    bool parse_array(Value& out, int depth) {
        ++position_;  // '['
        out = Value::make_array();
        skip_whitespace();
        if (at(']')) {
            ++position_;
            return true;
        }
        for (;;) {
            skip_whitespace();
            Value value;
            if (!parse_value(value, depth + 1)) {
                return false;
            }
            out.array().push_back(std::move(value));
            skip_whitespace();
            if (at(',')) {
                ++position_;
                continue;
            }
            if (at(']')) {
                ++position_;
                return true;
            }
            return fail("expected ',' or ']'");
        }
    }

    bool parse_string(std::string& out) {
        if (!at('"')) {
            return fail("expected a string");
        }
        ++position_;
        out.clear();
        while (position_ < text_.size()) {
            const char character = text_[position_++];
            if (character == '"') {
                return true;
            }
            if (character != '\\') {
                out.push_back(character);
                continue;
            }
            if (position_ >= text_.size()) {
                return fail("unterminated escape sequence");
            }
            const char escape = text_[position_++];
            switch (escape) {
                case '"':  out.push_back('"'); break;
                case '\\': out.push_back('\\'); break;
                case '/':  out.push_back('/'); break;
                case 'b':  out.push_back('\b'); break;
                case 'f':  out.push_back('\f'); break;
                case 'n':  out.push_back('\n'); break;
                case 'r':  out.push_back('\r'); break;
                case 't':  out.push_back('\t'); break;
                case 'u': {
                    unsigned int code = 0;
                    if (!parse_hex4(code)) {
                        return false;
                    }
                    // Surrogate pair: combine before encoding, otherwise anything outside
                    // the basic plane round-trips as two broken characters.
                    if (code >= 0xD800 && code <= 0xDBFF && position_ + 1 < text_.size() &&
                        text_[position_] == '\\' && text_[position_ + 1] == 'u') {
                        const std::size_t saved = position_;
                        position_ += 2;
                        unsigned int low = 0;
                        if (parse_hex4(low) && low >= 0xDC00 && low <= 0xDFFF) {
                            code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00);
                        } else {
                            position_ = saved;
                        }
                    }
                    append_utf8(out, code);
                    break;
                }
                default:
                    return fail("unrecognised escape sequence");
            }
        }
        return fail("unterminated string");
    }

    bool parse_hex4(unsigned int& out) {
        if (position_ + 4 > text_.size()) {
            return fail("truncated \\u escape");
        }
        out = 0;
        for (int i = 0; i < 4; ++i) {
            const char character = text_[position_++];
            out <<= 4;
            if (character >= '0' && character <= '9') {
                out |= static_cast<unsigned int>(character - '0');
            } else if (character >= 'a' && character <= 'f') {
                out |= static_cast<unsigned int>(character - 'a' + 10);
            } else if (character >= 'A' && character <= 'F') {
                out |= static_cast<unsigned int>(character - 'A' + 10);
            } else {
                return fail("invalid hex digit in \\u escape");
            }
        }
        return true;
    }

    static void append_utf8(std::string& out, unsigned int code) {
        if (code < 0x80) {
            out.push_back(static_cast<char>(code));
        } else if (code < 0x800) {
            out.push_back(static_cast<char>(0xC0 | (code >> 6)));
            out.push_back(static_cast<char>(0x80 | (code & 0x3F)));
        } else if (code < 0x10000) {
            out.push_back(static_cast<char>(0xE0 | (code >> 12)));
            out.push_back(static_cast<char>(0x80 | ((code >> 6) & 0x3F)));
            out.push_back(static_cast<char>(0x80 | (code & 0x3F)));
        } else {
            out.push_back(static_cast<char>(0xF0 | (code >> 18)));
            out.push_back(static_cast<char>(0x80 | ((code >> 12) & 0x3F)));
            out.push_back(static_cast<char>(0x80 | ((code >> 6) & 0x3F)));
            out.push_back(static_cast<char>(0x80 | (code & 0x3F)));
        }
    }

    bool parse_number(Value& out) {
        const std::size_t start = position_;
        if (at('-')) {
            ++position_;
        }
        while (position_ < text_.size() && text_[position_] >= '0' && text_[position_] <= '9') {
            ++position_;
        }
        if (at('.')) {
            ++position_;
            while (position_ < text_.size() && text_[position_] >= '0' && text_[position_] <= '9') {
                ++position_;
            }
        }
        if (at('e') || at('E')) {
            ++position_;
            if (at('+') || at('-')) {
                ++position_;
            }
            while (position_ < text_.size() && text_[position_] >= '0' && text_[position_] <= '9') {
                ++position_;
            }
        }
        if (position_ == start) {
            return fail("expected a value");
        }

        const std::string text = text_.substr(start, position_ - start);
        char* end = nullptr;
        const double value = std::strtod(text.c_str(), &end);
        if (end == text.c_str()) {
            position_ = start;
            return fail("malformed number");
        }
        out = Value(value);
        return true;
    }

    const std::string& text_;
    std::size_t position_ = 0;
    std::string error_;
};

void escape_into(std::string& out, const std::string& text) {
    out.push_back('"');
    for (char character : text) {
        switch (character) {
            case '"':  out += "\\\""; break;
            case '\\': out += "\\\\"; break;
            case '\b': out += "\\b"; break;
            case '\f': out += "\\f"; break;
            case '\n': out += "\\n"; break;
            case '\r': out += "\\r"; break;
            case '\t': out += "\\t"; break;
            default:
                if (static_cast<unsigned char>(character) < 0x20) {
                    static const char* kHex = "0123456789abcdef";
                    out += "\\u00";
                    out.push_back(kHex[(character >> 4) & 0xF]);
                    out.push_back(kHex[character & 0xF]);
                } else {
                    out.push_back(character);
                }
        }
    }
    out.push_back('"');
}

// Numbers are written back in the shortest form that reads the same, so that a value
// entered as 440 does not come back as 440.00000000000006.
void write_number(std::string& out, double value) {
    if (!std::isfinite(value)) {
        out += "0";
        return;
    }
    if (value == static_cast<double>(static_cast<long long>(value)) &&
        value > -1.0e15 && value < 1.0e15) {
        out += std::to_string(static_cast<long long>(value));
        return;
    }
    char buffer[40];
    for (int precision = 6; precision <= 17; ++precision) {
        std::snprintf(buffer, sizeof(buffer), "%.*g", precision, value);
        if (std::strtod(buffer, nullptr) == value) {
            break;
        }
    }
    out += buffer;
}

void serialize_into(std::string& out, const Value& value, bool pretty, int indent) {
    const std::string padding = pretty ? std::string(static_cast<std::size_t>(indent) * 2, ' ') : "";
    const std::string inner_padding =
        pretty ? std::string(static_cast<std::size_t>(indent + 1) * 2, ' ') : "";
    const char* newline = pretty ? "\n" : "";
    const char* space = pretty ? " " : "";

    switch (value.type()) {
        case Value::Type::Null:   out += "null"; break;
        case Value::Type::Bool:   out += value.as_bool() ? "true" : "false"; break;
        case Value::Type::Number: write_number(out, value.as_number()); break;
        case Value::Type::String: escape_into(out, value.as_string()); break;
        case Value::Type::Array: {
            if (value.array().empty()) {
                out += "[]";
                break;
            }
            out += "[";
            out += newline;
            for (std::size_t i = 0; i < value.array().size(); ++i) {
                out += inner_padding;
                serialize_into(out, value.array()[i], pretty, indent + 1);
                if (i + 1 < value.array().size()) {
                    out += ",";
                }
                out += newline;
            }
            out += padding;
            out += "]";
            break;
        }
        case Value::Type::Object: {
            if (value.object().empty()) {
                out += "{}";
                break;
            }
            out += "{";
            out += newline;
            for (std::size_t i = 0; i < value.object().size(); ++i) {
                out += inner_padding;
                escape_into(out, value.object()[i].first);
                out += ":";
                out += space;
                serialize_into(out, value.object()[i].second, pretty, indent + 1);
                if (i + 1 < value.object().size()) {
                    out += ",";
                }
                out += newline;
            }
            out += padding;
            out += "}";
            break;
        }
    }
}

}  // namespace

const Value* Value::find(const std::string& key) const {
    if (type_ != Type::Object) {
        return nullptr;
    }
    for (const auto& entry : object_) {
        if (entry.first == key) {
            return &entry.second;
        }
    }
    return nullptr;
}

void Value::set(const std::string& key, Value value) {
    if (type_ != Type::Object) {
        type_ = Type::Object;
        object_.clear();
    }
    for (auto& entry : object_) {
        if (entry.first == key) {
            entry.second = std::move(value);
            return;
        }
    }
    object_.emplace_back(key, std::move(value));
}

void Value::push_back(Value value) {
    if (type_ != Type::Array) {
        type_ = Type::Array;
        array_.clear();
    }
    array_.push_back(std::move(value));
}

bool parse(const std::string& text, Value& out, std::string& error) {
    Parser parser(text);
    if (!parser.parse(out)) {
        error = parser.error();
        return false;
    }
    return true;
}

std::string serialize(const Value& value, bool pretty) {
    std::string out;
    serialize_into(out, value, pretty, 0);
    if (pretty) {
        out.push_back('\n');
    }
    return out;
}

}  // namespace json
}  // namespace soundgraph
