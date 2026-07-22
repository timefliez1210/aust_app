#!/usr/bin/env python3
"""Export YOLOv11n to CoreML format for the DepthCapture plugin.

Usage (pin the trio — a bare `pip install ultralytics coremltools` pulls
numpy 2.x + a too-new torch and the CoreML converter dies with
"TypeError: only 0-dimensional arrays can be converted to Python scalars"):
    pip install "numpy==1.26.4" "torch==2.4.0" "torchvision==0.19.0" "coremltools==8.1" ultralytics
    python scripts/export-yolo-coreml.py

This produces yolo11n.mlpackage in the plugin's iOS directory.
After export, commit the model and rebuild.
"""

from pathlib import Path
from ultralytics import YOLO

PLUGIN_DIR = Path(__file__).resolve().parent.parent / "plugins" / "capacitor-depth-capture" / "ios" / "Plugin"

def main():
    model = YOLO("yolo11n.pt")
    output = model.export(format="coreml", nms=True, imgsz=640)

    src = Path(output)
    dst = PLUGIN_DIR / "yolo11n.mlpackage"

    if dst.exists():
        import shutil
        shutil.rmtree(dst)

    src.rename(dst)
    print(f"Exported to {dst}")
    print(f"Size: {sum(f.stat().st_size for f in dst.rglob('*') if f.is_file()) / 1024 / 1024:.1f} MB")


if __name__ == "__main__":
    main()
