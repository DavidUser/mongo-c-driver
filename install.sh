./install-dependencies.sh
./autogen.sh
./configure --with-libbson-bundled --enable-ssl=openssl
cd ./src/libbson
./configure --enable-man-pages --enable-static
cd -
make
sudo make install
