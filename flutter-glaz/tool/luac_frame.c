/*
 * Compiles one Lua file to bytecode the glasses load, written by the very
 * Lua the firmware runs. The debug information goes, but for the file's
 * name: local variables' names, upvalues' names and the line numbers, a
 * byte an instruction. The glasses' memory is small, and they were some
 * 15 KB of the app's code loaded (docs/FRAME.md 11). An error on the
 * glasses says the file and no line: 'glaz.lua:-1: attempt to call a nil
 * value (field 'x')'; the tests run the source, lines and all. Nothing
 * on the glasses needs the lines: the firmware's hooks -- the watchdog,
 * the break, taps, Bluetooth -- count instructions (LUA_MASKCOUNT), so
 * they run as often without them.
 *
 * Built from the firmware's own libraries/lua (tool/compile_lua.sh). Lua
 * 5.4 bytecode carries the sizes of an instruction, an integer and a
 * number and checks them on load; with the firmware's luaconf.h (64-bit
 * integers, doubles) a 32-bit ARM and a 64-bit laptop agree on all three,
 * and both are little-endian.
 *
 *   luac_frame in.lua out.luac [name]
 *
 * name: what errors call the file, glaz.lua or apps/recorder/recorder.lua;
 * in.lua by default.
 *
 * Prints the FNV-1a hash of in.lua, in hex: the app compares it with the
 * source it carries, and uploads bytecode only when they match
 * (lib/frame/upload.dart).
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "lauxlib.h"
#include "lua.h"
#include "lobject.h"

/* The debug information out of f and the functions in it, but for the
 * source's name, which lua_dump() keeps only when not stripping: so it is
 * done here, and the dump is not stripped. */
static void strip(Proto *f)
{
    f->sizelocvars = 0;
    f->sizelineinfo = 0;
    f->sizeabslineinfo = 0;
    for (int i = 0; i < f->sizeupvalues; i++)
    {
        f->upvalues[i].name = NULL;
    }
    for (int i = 0; i < f->sizep; i++)
    {
        strip(f->p[i]);
    }
}

static int writer(lua_State *L, const void *p, size_t size, void *out)
{
    (void)L;
    return fwrite(p, 1, size, (FILE *)out) != size;
}

int main(int argc, char **argv)
{
    if (argc != 3 && argc != 4)
    {
        fprintf(stderr, "usage: %s in.lua out.luac [name]\n", argv[0]);
        return 2;
    }

    FILE *in = fopen(argv[1], "rb");
    if (!in)
    {
        perror(argv[1]);
        return 1;
    }
    fseek(in, 0, SEEK_END);
    long size = ftell(in);
    fseek(in, 0, SEEK_SET);
    char *src = malloc(size > 0 ? size : 1);
    if (fread(src, 1, size, in) != (size_t)size)
    {
        perror(argv[1]);
        return 1;
    }
    fclose(in);

    unsigned int hash = 2166136261u;
    for (long i = 0; i < size; i++)
    {
        hash = (hash ^ (unsigned char)src[i]) * 16777619u;
    }

    lua_State *L = luaL_newstate();
    char chunk[512];
    snprintf(chunk, sizeof chunk, "@%s", argc == 4 ? argv[3] : argv[1]);
    if (luaL_loadbuffer(L, src, size, chunk) != LUA_OK)
    {
        fprintf(stderr, "%s\n", lua_tostring(L, -1));
        return 1;
    }
    strip(((const LClosure *)lua_topointer(L, -1))->p);

    FILE *out = fopen(argv[2], "wb");
    if (!out)
    {
        perror(argv[2]);
        return 1;
    }
    if (lua_dump(L, writer, out, 0) != 0 || fclose(out) != 0)
    {
        fprintf(stderr, "%s: write failed\n", argv[2]);
        return 1;
    }

    printf("%08x\n", hash);
    lua_close(L);
    free(src);
    return 0;
}
