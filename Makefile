.PHONY: app debug-app icon site test cli install clean

# Build build/Headroom.app (release, ad-hoc signed).
app:
	scripts/make-app.sh release

# Debug build: clean-ups are always a dry run.
debug-app:
	scripts/make-app.sh debug

# Re-render Resources/AppIcon.icns from docs/assets/icon.svg after changing the logo.
icon:
	swift scripts/make-icon.swift

# Serve the landing page and guide at http://localhost:8765
site:
	cd docs && python3 -m http.server 8765

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
