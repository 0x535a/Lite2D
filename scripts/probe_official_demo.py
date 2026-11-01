#!/usr/bin/env python3
"""Build and run the official sample with internal GPU readback, no UI automation.

Temporarily instruments only mainMinimum.cpp, restores it even on build failure,
and runs a bounded 90-frame test. The capture is the application's GL buffer,
not a screenshot or desktop recording.
"""
from pathlib import Path
import subprocess
import os

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "vendor/CubismNativeSamples/Samples/OpenGL/Demo/proj.mac.cmake/src/mainMinimum.cpp"


def main():
    output = ROOT / ".local/verification/official"
    output.mkdir(parents=True, exist_ok=True)
    original = SOURCE.read_bytes()
    source = original.decode("utf-8-sig")
    marker = "        // バッファの入れ替え\n        glfwSwapBuffers(_window);"
    probe = r'''
        static int probeFrame = 0;
        ++probeFrame;
        if (probeFrame == 15 || probeFrame == 75) {
            std::vector<unsigned char> rgba(width * height * 4);
            glFinish();
            glReadPixels(0, 0, width, height, GL_RGBA, GL_UNSIGNED_BYTE, rgba.data());
            unsigned long long colored = 0;
            for (size_t p = 0; p < rgba.size(); p += 4)
                if (rgba[p] > 10 || rgba[p+1] > 10 || rgba[p+2] > 10) ++colored;
            std::string base = std::string(std::getenv("LITE2D_PROBE_DIR")) + "/frame-" + std::to_string(probeFrame);
            FILE* capture = std::fopen((base + ".rgba").c_str(), "wb");
            std::fwrite(rgba.data(), 1, rgba.size(), capture);
            std::fclose(capture);
            std::printf("PROBE frame=%d size=%dx%d colored=%llu error=%u\n", probeFrame, width, height, colored, glGetError());
            std::fflush(stdout);
        }
        if (probeFrame >= 90) glfwSetWindowShouldClose(_window, true);
'''
    if marker not in source:
        raise RuntimeError("Pinned sample instrumentation point has changed")
    instrumented = "#include <vector>\n#include <cstdio>\n#include <cstdlib>\n" + source.replace(marker, probe + marker)
    try:
        SOURCE.write_text(instrumented)
        with (output / "build.log").open("w") as log:
            subprocess.run(["cmake", "--build", "build/official-minimum", "--parallel", "6"],
                           cwd=ROOT, stdout=log, stderr=subprocess.STDOUT, check=True)
    finally:
        SOURCE.write_bytes(original)
    env = dict(os.environ, LITE2D_PROBE_DIR=str(output))
    with (output / "run.log").open("w") as log:
        subprocess.run([str(ROOT / "build/official-minimum/bin/Demo/Demo")], cwd=ROOT,
                       env=env, stdout=log, stderr=subprocess.STDOUT, timeout=45, check=True)
    print((output / "run.log").read_text())


if __name__ == "__main__":
    main()
