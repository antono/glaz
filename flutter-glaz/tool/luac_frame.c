/*
 * Compiles one Lua file to bytecode the glasses load, written by the very
 * Lua the firmware runs. Of the debug information only the names of local
 * variables go -- the most of it. Line numbers stay, with the file's name,
 * so an error on the glasses says where: 'frame_app.lua:1234: attempt to
 * call a nil value (field 'x')', the line in the repository, since what is
 * compiled is the repository's file. This is built
 * from the firmware's own libraries/lua (tool/compile_lua.sh). Lua 5.4
 * bytecode carries the sizes of an instruction, an integer and a number and
 * checks them on load; with the firmware's luaconf.h (64-bit integers,
 * doubles) a 32-bit ARM and a 64-bit laptop agree on all three, and both are
 * little-endian.
 *
 *   luac_frame in.lua out.luac [name]
 *
 * name: what errors call the file, frame_app.lua or modules/recorder.lua;
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

/* Local variables' names out of f and the functions in it; the rest of the
 * debug information is dumped as it is. */
static void drop_locals(Proto *f)
{
    f->sizelocvars = 0;
    for (int i = 0; i < f->sizep; i++)
    {
        drop_locals(f->p[i]);
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
    drop_locals(((const LClosure *)lua_topointer(L, -1))->p);

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
