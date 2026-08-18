.PHONY: all build run install uninstall clean

all: build

build:
	@./scripts/build.sh

run: build
	@./headset_dictation

install:
	@./scripts/install_daemon.sh

uninstall:
	@./scripts/uninstall_daemon.sh

clean:
	@rm -f headset_dictation
