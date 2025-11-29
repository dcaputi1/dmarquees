# Makefile for marquee-drm.c
# Single-file project with logging and clang-tidy support

# Compiler
CC = gcc

# Target executable
TARGET = dmarquees

# Source files
SRCS = dmarquees.c helpers.c

# Compiler and linker flags
CFLAGS = -Wall -O2 $(shell pkg-config --cflags libdrm)
LDFLAGS = $(shell pkg-config --libs libdrm) -lpng

# Log file
LOGFILE = build.log

# Default build
all: $(TARGET)

# Install directory (can be overridden: make INSTALL_DIR=/some/path install)
INSTALL_DIR ?= $(HOME)/marquees

# Compile object file
%.o: %.c
	@echo "Compiling $<..."
	@$(CC) $(CFLAGS) -c $< -o $@ 2>&1 | tee -a $(LOGFILE)

# Link executable
$(TARGET): $(SRCS:.c=.o)
	@echo "Linking $@..."
	@$(CC) -o $@ $^ $(LDFLAGS) 2>&1 | tee -a $(LOGFILE)

# Install the binary to $(INSTALL_DIR)
install: $(TARGET)
	@echo "Installing $(TARGET) to $(INSTALL_DIR)..."
	@mkdir -p $(INSTALL_DIR)
	@cp -p $(TARGET) $(INSTALL_DIR)/
	@echo "Installed: $(INSTALL_DIR)/$(TARGET)"

	# Install runtime resources (images directory) if present
	@if [ -d images ]; then \
		echo "Copying images/ to $(INSTALL_DIR)/images..."; \
		cp -a images $(INSTALL_DIR)/; \
		echo "Installed: $(INSTALL_DIR)/images"; \
	fi

# Uninstall (remove installed binary)
uninstall:
	@echo "Removing $(INSTALL_DIR)/$(TARGET) if present..."
	@rm -f $(INSTALL_DIR)/$(TARGET) || true
	@echo "Removing $(INSTALL_DIR)/images if present..."
	@rm -rf $(INSTALL_DIR)/images || true
	# Try to remove the install dir if empty (don't force removal of non-empty dirs)
	@rmdir --ignore-fail-on-non-empty $(INSTALL_DIR) || true
	@echo "Uninstall complete."

# Generate compile_commands.json safely
compile_commands.json:
	@echo "Generating compile_commands.json..."
	@bear -- $(CC) $(CFLAGS) -c $(SRCS) 2>/dev/null || true

# Clean build artifacts
clean:
	@echo "Cleaning..."
	@rm -f $(TARGET) *.o $(LOGFILE) compile_commands.json
