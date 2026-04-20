CXX = clang++
CXXFLAGS = -std=c++17 -Wall -O3 -fobjc-arc
LDFLAGS = -framework Foundation -framework Metal -framework MetalPerformanceShaders -framework CoreGraphics -framework ImageIO -framework MetalKit

SRC = main.mm Renderer.mm
OBJ = $(SRC:.mm=.o)

EXEC = metal_renderer

all: $(EXEC)

$(EXEC): $(OBJ)
	$(CXX) $(CXXFLAGS) $(LDFLAGS) -o $@ $^

%.o: %.mm
	$(CXX) $(CXXFLAGS) -c $< -o $@

clean:
	rm -f $(OBJ) $(EXEC)

.PHONY: all clean
