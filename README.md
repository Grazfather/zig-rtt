# RTT Implementation in Zig

Work in progress. Goal is to integrate into MicroZig. For now this repo serves as a development/test bed that uses the rp2040 to test RTT functionality.

## Current Status
- Allows writing to an up channel (target -> probe), and reading from a down channel (probe -> target)
    - Original segger code allowed read/write for both types of channels, but this doesn't seem particularly useful
- Allows `comptime` configuration of _all_ up/down channels which is a nice improvement over Segger's code which only allowed up/down channel 0 to be configured at compile time. 
- Exposes writer/reader APIs for easy integration into Zig's std library functions that use these

## TODO:
- Implementation
    - Add locking (conditionally?) to make API threadsafe and match original Segger code 
    - Add architecture detection for choosing correct memory barrier/lock implementation
    - Allow linker section placement of control block via build options
    - Add ability to set/switch virtual terminal number
    - Easy "vanilla" config preset for those who don't want to mess with channel configurations, can make it match Segger's default config
- Testing:
    - Max number of up/down channels supported by RTT
    - Max virtual terminals supported by RTT




