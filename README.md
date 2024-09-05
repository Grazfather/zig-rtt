# RTT Implementation in Zig

Work in progress. Goal is to integrate into MicroZig. For now this repo serves as a development/test bed that uses the rp2040 to test RTT functionality.

Functionality supported from original:
- 

Functionality not yet supported from original:
- 

# TODO:
- Implementation
    - add memory barriers where neccessary
    - add locking where neccessary 
    - allow linker section placement via build options
- Testing:
    - Max number of up/down channels supported by RTT
    - Max virtual terminals supported by RTT

# RTT Notes

## Usage

Segger has quite good documentation on how RTT works on their wiki [here](https://wiki.segger.com/RTT);


### Basic

For the purpose of text logging, Segger's tools (RTT Viewer) only use channel 0. The configuration function `TODO()` offers a simple configuration if you just want to log text.

### Advanced

Because of the simplicity of RTT's design (in-memory ring buffers), there is a lot of flexibility in how it can be configured. For this... TODO


