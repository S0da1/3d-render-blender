#include <iostream>
#include <string>
int main(int argc, const char* argv[]) {
    for (int i=0; i<argc; i++) std::cout << i << ": [" << argv[i] << "]\n";
    return 0;
}
