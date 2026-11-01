"""Scope the R5 renderer's two GL resource singletons to the current context."""
from pathlib import Path
import sys

framework, output = map(Path, sys.argv[1:])
output.mkdir(parents=True, exist_ok=True)
for name in ["CubismShader_OpenGLES2", "CubismOffscreenManager_OpenGLES2"]:
    original = framework / "src/Rendering/OpenGL" / (name + ".cpp")
    source = original.read_text(encoding="utf-8-sig")
    declaration = f"{name}* s_instance" + (" = nullptr;" if "Offscreen" in name else ";")
    replacement = (f"std::map<CGLContextObj, {name}*> s_instances;\n"
                   "#define s_instance s_instances[CGLGetCurrentContext()]")
    if source.count(declaration) != 1:
        raise RuntimeError(f"Pinned singleton declaration changed in {name}")
    source = source.replace(declaration, replacement)
    # Erase the context slot when its resources are explicitly destroyed.
    source = source.replace("s_instance = NULL;", "s_instances.erase(CGLGetCurrentContext());")
    source = source.replace("s_instance = nullptr;", "s_instances.erase(CGLGetCurrentContext());")
    destination = output / (name + ".cpp")
    generated = "#include <GL/glew.h>\n#include <map>\n#include <OpenGL/OpenGL.h>\n" + source
    if not destination.exists() or destination.read_text() != generated:
        destination.write_text(generated)
