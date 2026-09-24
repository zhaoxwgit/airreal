A sample command-line application with an entrypoint in `bin/`, library code
in `lib/`, and example unit test in `test/`.


dart compile exe --target-os=linux --target-arch=x64 bin/server.dart -o web_server


chmod +x web_server
./web_server

复制web-server.service 到 /etc/systemd/system 目录下
sudo systemctl daemon-reload
sudo systemctl enable web-server.service
sudo systemctl start web-server.service
sudo systemctl status web-server.service
