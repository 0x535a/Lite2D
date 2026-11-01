#pragma once
#include <memory>
#include <string>
#include <map>
#include <vector>

namespace Lite2D {
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
    bool expression(const std::string& name);
    void idle(const std::string& group);
    std::map<std::string,int> groups() const;
    std::vector<std::string> expressions() const;
    float canvasAspect() const;
private:
    class Impl;
    std::unique_ptr<Impl> impl;
};
}
