#pragma once
#include <memory>
#include <stdexcept>
#include <string>
#include <map>
#include <vector>

namespace Lite2D {
class LocalizedEngineError : public std::runtime_error {
public:
    const std::string key;
    LocalizedEngineError(const std::string& key, const std::string& detail)
        : std::runtime_error(detail), key(key) {}
};
void startRuntime(const std::string& resources);
void stopRuntime();
class NativeHost {
public:
    NativeHost();
    ~NativeHost();
    void load(const std::string& path, int width, int height);
    void update(double dt, float x, float y);
    void render(int width, int height, float scale);
    bool play(const std::string& group, int index);
    bool playInteraction(const std::string& group);
    bool interactionPlaying() const;
    bool expression(const std::string& name);
    void weights(const std::map<std::string,std::vector<double>>& weights);
    void idle(const std::string& group);
    std::map<std::string,int> groups() const;
    std::vector<std::string> expressions() const;
    float canvasAspect() const;
private:
    class Impl;
    std::unique_ptr<Impl> impl;
};
}
