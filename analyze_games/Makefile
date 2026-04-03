# Makefile for analyze_games
# MAME game analyzer and config generator

# Compiler
CXX = g++

TARGETS = analyze_games

# Source files
SRCS_ANALYZE_GAMES = analyze_games.cpp

# Compiler and linker flags
CXXFLAGS = -Wall -O2 -std=c++17
LDFLAGS = -ltinyxml2

# Default build
all: $(TARGETS)

# Compile object file
%.o: %.cpp
	@echo "Compiling $<..."
	@$(CXX) $(CXXFLAGS) -c $< -o $@

# Link analyze_games executable
analyze_games: analyze_games.o
	@echo "Linking $@..."
	@$(CXX) -o $@ $^ $(LDFLAGS)
	@echo "Built: $@"



# Clean build artifacts
clean:
	@echo "Cleaning analyze_games build artifacts..."
	@rm -f $(TARGETS) *.o

.PHONY: all clean
