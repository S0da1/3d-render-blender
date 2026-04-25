#import <Foundation/Foundation.h>
#include "Renderer.h"
#include <iostream>
#include <string>

int main(int argc, const char * argv[]) {
    @autoreleasepool {
        if (argc < 6) {
            std::cerr << "Usage: " << argv[0] << " <input.obj> <scene.json> <output.png> <width> <height>" << std::endl;
            return 1;
        }
        
        std::string inputObj = argv[1];
        std::string inputJson = argv[2];
        std::string outputImg = argv[3];
        int width = std::stoi(argv[4]);
        int height = std::stoi(argv[5]);
        std::string generatedShaderPath = (argc >= 7) ? argv[6] : "";
        
        Renderer renderer;
        bool success = renderer.handleScene(inputObj, inputJson, outputImg, width, height, generatedShaderPath);
        
        if (success) {
            std::cout << "Rendering completed successfully." << std::endl;
        } else {
            std::cerr << "Rendering failed." << std::endl;
            return 1;
        }
    }
    return 0;
}
