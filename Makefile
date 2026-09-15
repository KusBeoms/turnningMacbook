turn: turn.m
	clang -O2 -fobjc-arc -framework Foundation -framework CoreGraphics -framework ApplicationServices turn.m -o turn

install: turn
	install -m 755 turn /usr/local/bin/turn

clean:
	rm -f turn

.PHONY: install clean
