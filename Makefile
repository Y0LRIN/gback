# Makefile for gback development and packaging

.PHONY: install uninstall clean test-syntax test-basic aur-build aur-test

# Installation paths
PREFIX ?= /usr
BINDIR = $(PREFIX)/bin
SYSCONFDIR = /etc
DOCDIR = $(PREFIX)/share/doc/gback
LICENSEDIR = $(PREFIX)/share/licenses/gback

# Install the package (for development/testing)
install:
	@echo "Installing gback..."
	install -Dm755 gback.sh "$(DESTDIR)$(BINDIR)/gback"
	install -Dm644 example.config.json "$(DESTDIR)$(SYSCONFDIR)/gback/gback.config.json"
	install -Dm644 README.md "$(DESTDIR)$(DOCDIR)/README.md"
	install -Dm644 LICENSE "$(DESTDIR)$(LICENSEDIR)/LICENSE"
	install -dm755 "$(DESTDIR)/var/lib/gback"
	install -dm755 "$(DESTDIR)/var/log/gback"
	@echo "Installation complete!"
	@echo "Edit $(SYSCONFDIR)/gback/gback.config.json to configure"

# Uninstall the package
uninstall:
	@echo "Uninstalling gback..."
	rm -f "$(DESTDIR)$(BINDIR)/gback"
	rm -rf "$(DESTDIR)$(SYSCONFDIR)/gback"
	rm -rf "$(DESTDIR)$(DOCDIR)"
	rm -rf "$(DESTDIR)$(LICENSEDIR)"
	rmdir "$(DESTDIR)/var/lib/gback" 2>/dev/null || true
	rmdir "$(DESTDIR)/var/log/gback" 2>/dev/null || true
	@echo "Uninstallation complete!"

# Clean build artifacts
clean:
	rm -f *.pkg.tar.* *.log
	rm -rf src/ pkg/

# Test syntax
test-syntax:
	@echo "Testing bash syntax..."
	bash -n gback.sh
	@echo "Syntax check passed!"

# Basic functionality test
test-basic: test-syntax
	@echo "Testing basic functionality..."
	./gback.sh --help >/dev/null
	./gback.sh -l 2>/dev/null || true
	@echo "Basic tests passed!"

# Build AUR package (requires makepkg)
aur-build:
	@echo "Building AUR package..."
	makepkg -s
	@echo "Package built successfully!"

# Test AUR package installation
aur-test: aur-build
	@echo "Testing AUR package installation..."
	makepkg -si
	@echo "Testing installed package..."
	gback --help >/dev/null
	@echo "AUR package test completed!"

# Generate .SRCINFO for AUR
srcinfo:
	@echo "Generating .SRCINFO..."
	makepkg --printsrcinfo > .SRCINFO
	@echo ".SRCINFO generated!"

# Help
help:
	@echo "Available targets:"
	@echo "  install     - Install gback system-wide"
	@echo "  uninstall   - Remove gback from system"
	@echo "  clean       - Clean build artifacts"
	@echo "  test-syntax - Test bash syntax"
	@echo "  test-basic  - Test basic functionality"
	@echo "  aur-build   - Build AUR package"
	@echo "  aur-test    - Build and test AUR package"
	@echo "  srcinfo     - Generate .SRCINFO for AUR"
	@echo "  help        - Show this help"
