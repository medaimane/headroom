.PHONY: app debug-app test cli install clean

# Build build/Headroom.app (release, ad-hoc signed).
app:
	scripts/make-app.sh release

# Debug build: clean-ups are always a dry run.
debug-app:
	scripts/make-app.sh debug

test:
	swift test

# Read-only reports, e.g. `make cli ARGS=storage`
cli:
	swift run headroom-cli $(ARGS)

# Copies the app to ~/Applications. Run it yourself when you're ready.
install: app
	mkdir -p "$(HOME)/Applications"
	rm -rf "$(HOME)/Applications/Headroom.app"
	cp -R build/Headroom.app "$(HOME)/Applications/Headroom.app"
	@echo "Installed to ~/Applications/Headroom.app"

clean:
	rm -rf .build build
