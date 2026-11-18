# What 观羽.app bundles (besides BirdCM's own MIT code)

| Component | Where in the app | Licence |
|---|---|---|
| CPython 3.12 (python-build-standalone build, via uv) | `Contents/Resources/engine/python` | PSF License (`Python-LICENSE.txt`); the build's own bundled libraries (OpenSSL, SQLite, zlib, xz, libffi, …) keep theirs |
| The engine's Python dependencies, exactly as locked in `engine/uv.lock` (PyTorch, torchvision, open_clip, transformers, timm, safetensors, numpy, Pillow, rawpy/LibRaw, OpenCV, ONNX Runtime, FastAPI, Starlette, uvicorn, pydantic, …) | `…/python/lib/python3.12/site-packages` | Each package's licence file sits in its `*.dist-info` directory there (BSD / MIT / Apache-2.0 for most; rawpy MIT with LibRaw LGPL-2.1 / CDDL-1.0) |
| ExifTool by Phil Harvey | `Contents/Resources/engine/exiftool` | Same terms as Perl itself: Artistic License or GPL (`ExifTool-LICENSE.txt`, `ExifTool-GPL.pod`); unmodified; runs on macOS's own `/usr/bin/perl` |
| The built web UI (React, Leaflet) | `Contents/Resources/engine/web` | MIT / BSD-2-Clause |

Model files are not in the app; they are downloaded on first use and listed with their terms in `NOTICE.md`.
