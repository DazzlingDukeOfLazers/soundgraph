#!/bin/sh
# Places the plugin SDKs under runtime-clap/sdks/ (gitignored), pinned so that every
# clone builds the same plugin. The default build never needs these; only
# -DSOUNDGRAPH_CLAP=ON does. clap-wrapper fetches its own pinned VST3 SDK and Apple
# AudioUnitSDK at first configure, into runtime-clap/sdks/_fetch.
set -e

CLAP_TAG="1.2.6"
CLAP_WRAPPER_TAG="v0.16.0"

cd "$(dirname "$0")/../runtime-clap"
mkdir -p sdks
cd sdks

clone() {
    name=$1; url=$2; tag=$3
    if [ -d "$name" ]; then
        echo "$name already present, leaving it alone"
    else
        git clone --depth 1 --branch "$tag" "$url" "$name"
    fi
}

clone clap         https://github.com/free-audio/clap.git         "$CLAP_TAG"
clone clap-wrapper https://github.com/free-audio/clap-wrapper.git "$CLAP_WRAPPER_TAG"

echo "done. configure with -DSOUNDGRAPH_CLAP=ON"
