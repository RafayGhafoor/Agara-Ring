#!/bin/sh
# iPad layout capture (store launch phase 1d): runs IPadLayoutCaptureTests on an iPad simulator and uprights the
# landscape PNGs (XCUIScreen returns the portrait framebuffer, so landscape shots come back rotated 90 degrees).
# usage: scripts/ipad_layout_capture.sh "iPad Pro 13-inch (M5)"   (or "iPad mini (A17 Pro)")
set -e
DEVICE="${1:-iPad Pro 13-inch (M5)}"
OUT="${IPAD_SHOT_DIR:-$(cd "$(dirname "$0")/../.." && pwd)/captures/ipad-layout}"
cd "$(dirname "$0")/.."
mkdir -p "$OUT"
TEST_RUNNER_IPAD_SHOT_DIR="$OUT" xcodebuild test -project PulseLoop.xcodeproj -scheme AgaraRingUITests -sdk iphonesimulator \
  -destination "platform=iOS Simulator,name=$DEVICE" -derivedDataPath /tmp/plipad CODE_SIGNING_ALLOWED=NO \
  -only-testing:AgaraRingUITests/IPadLayoutCaptureTests 2>&1 | grep -E "error:|Executed [0-9]+ tests|\*\* TEST"
python3 - "$OUT" <<'PY'
import glob, sys
from PIL import Image
for f in glob.glob(sys.argv[1] + "/*-landscape-*.png"):
    im = Image.open(f)
    if im.height > im.width:          # raw portrait framebuffer -> rotate the pixels upright
        im = im.transpose(Image.Transpose.ROTATE_90)
    im.save(f)                        # re-save without the EXIF orientation tag
PY
echo "captures in $OUT"
