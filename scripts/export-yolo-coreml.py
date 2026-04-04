#!/usr/bin/env python3
"""Export YOLOv11n to CoreML format for the DepthCapture plugin.

Usage:
    pip install ultralytics
    python scripts/export-yolo-coreml.py

This produces YOLOv11n.mlpackage in the plugin's iOS directory.
After export, commit the model and rebuild.
"""

from pathlib import Path
from ultralytics import YOLO

PLUGIN_DIR = Path(__file__).resolve().parent.parent / "plugins" / "capacitor-depth-capture" / "ios" / "Plugin"

def main():
    model = YOLO("yolo11n.pt")
    output = model.export(format="coreml", nms=True, imgsz=640)

    src = Path(output)
    dst = PLUGIN_DIR / "YOLOv11n.mlpackage"

    if dst.exists():
        import shutil
        shutil.rmtree(dst)

    src.rename(dst)
    print(f"Exported to {dst}")
    print(f"Size: {sum(f.stat().st_size for f in dst.rglob('*') if f.is_file()) / 1024 / 1024:.1f} MB")


if __name__ == "__main__":
    main()
