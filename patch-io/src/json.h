// A small, self-contained JSON reader and writer.
//
// This exists so that patch-io has no third-party dependency and no configure-time
// network access, and so that the same code compiles unmodified for WASM and ESP32.
// See docs/decisions.md — it is deliberately confined to patch-io.
//
// Objects keep their insertion order, which is what makes a saved patch a stable diff.
#pragma once

#include <memory>
#include <string>
#include <utility>
#include <vector>

namespace soundgraph {
namespace json {

class Value;
using Object = std::vector<std::pair<std::string, Value>>;
using Array = std::vector<Value>;

class Value {
public:
    enum class Type { Null, Bool, Number, String, Array, Object };

    Value() = default;
    explicit Value(bool value) : type_(Type::Bool), bool_(value) {}
    explicit Value(double value) : type_(Type::Number), number_(value) {}
    explicit Value(int value) : type_(Type::Number), number_(static_cast<double>(value)) {}
    explicit Value(const char* value) : type_(Type::String), string_(value) {}
    explicit Value(std::string value) : type_(Type::String), string_(std::move(value)) {}
    explicit Value(Array value) : type_(Type::Array), array_(std::move(value)) {}
    explicit Value(Object value) : type_(Type::Object), object_(std::move(value)) {}

    Type type() const { return type_; }
    bool is_null() const { return type_ == Type::Null; }
    bool is_bool() const { return type_ == Type::Bool; }
    bool is_number() const { return type_ == Type::Number; }
    bool is_string() const { return type_ == Type::String; }
    bool is_array() const { return type_ == Type::Array; }
    bool is_object() const { return type_ == Type::Object; }

    bool as_bool(bool fallback = false) const { return is_bool() ? bool_ : fallback; }
    double as_number(double fallback = 0.0) const { return is_number() ? number_ : fallback; }
    const std::string& as_string() const { return string_; }

    const Array& array() const { return array_; }
    Array& array() { return array_; }
    const Object& object() const { return object_; }
    Object& object() { return object_; }

    // Returns null if absent or if this value is not an object.
    const Value* find(const std::string& key) const;

    void set(const std::string& key, Value value);
    void push_back(Value value);

    static Value make_object() {
        Value value;
        value.type_ = Type::Object;
        return value;
    }
    static Value make_array() {
        Value value;
        value.type_ = Type::Array;
        return value;
    }

private:
    Type type_ = Type::Null;
    bool bool_ = false;
    double number_ = 0.0;
    std::string string_;
    Array array_;
    Object object_;
};

// On failure, `error` receives a message including a line and column.
bool parse(const std::string& text, Value& out, std::string& error);

std::string serialize(const Value& value, bool pretty);

}  // namespace json
}  // namespace soundgraph
