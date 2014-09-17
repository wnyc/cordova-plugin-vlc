#!/bin/bash

# reference: https://wiki.videolan.org/VLCKit/#Building_the_framework_for_iOS

echo 'Building VLC for iOS framework'

echo 'Cloning VLC repo...'
rm -fr VLCKit
git clone git://git.videolan.org/vlc-bindings/VLCKit.git

echo 'Moving patches into cloned VLC repo...'
cp patches/ios/* VLCKit/MobileVLCKit/patches

cd VLCKit
echo 'Building framework for device...'
./buildMobileVLCKit.sh
echo 'Building framework for simulator...'
./buildMobileVLCKit.sh -s
echo 'Creating embedded framework...'
./buildMobileVLCKit.sh -f

echo 'Moving embedded framework to plugin directory...'
mv build/MobileVLCKit.framework ../src/ios/MobileVLCKit.framework

echo 'Finished! Do not forget to commit and push to master.'


