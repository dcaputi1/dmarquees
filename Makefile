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

# Compile object file
%.o: %.c
	@echo "Compiling $<..."
	@$(CC) $(CFLAGS) -c $< -o $@ 2>&1 | tee -a $(LOGFILE)

# Link executable
$(TARGET): $(SRCS:.c=.o)
	@echo "Linking $@..."
	@$(CC) -o $@ $^ $(LDFLAGS) 2>&1 | tee -a $(LOGFILE)

# Generate compile_commands.json safely
compile_commands.json:
	@echo "Generating compile_commands.json..."
	@bear -- $(CC) $(CFLAGS) -c $(SRCS) 2>/dev/null || true

# Clean build artifacts
clean:
	@echo "Cleaning..."
	@rm -f $(TARGET) *.o $(LOGFILE) compile_commands.json
