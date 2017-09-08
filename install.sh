./install-dependencies.sh
./autogen.sh --with-libbson-bundled
make
cd ./src/libbson
./configure --enable-man-pages --enable-static
cd -
sudo make install
