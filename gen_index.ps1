#requires -Version 5.1
<#
.SYNOPSIS
Generates index.json with BLAKE3 hashes, without external dependencies.
.EXAMPLE
powershell -NoProfile -ExecutionPolicy Bypass -File .\gen_index.ps1
.EXAMPLE
.\gen_index.ps1 -BaseDirectory D:\translations -OutputPath D:\translations\index.json
#>
[CmdletBinding()]
param(
    [string] $BaseDirectory = '.',
    [string] $OutputPath = 'index.json'
)

$ErrorActionPreference = 'Stop'

if (-not ('GenIndex.Generator' -as [type])) {
    Add-Type -Language CSharp -TypeDefinition @'
using System;
using System.IO;
using System.Collections.Generic;
using System.Text;

namespace GenIndex
{
    // Unkeyed BLAKE3, 32-byte output. Algorithm reference (CC0/Apache-2.0):
    // https://github.com/BLAKE3-team/BLAKE3/blob/master/reference_impl/reference_impl.rs
    public static class Blake3
    {
        private static readonly uint[] IV = {
            0x6A09E667, 0xBB67AE85, 0x3C6EF372, 0xA54FF53A,
            0x510E527F, 0x9B05688C, 0x1F83D9AB, 0x5BE0CD19
        };
        private static readonly int[] Permutation = {
            2, 6, 3, 10, 7, 0, 4, 13, 1, 11, 12, 5, 9, 14, 15, 8
        };
        private const uint ChunkStart = 1, ChunkEnd = 2, Parent = 4, Root = 8;

        private static uint Rotate(uint x, int bits)
        {
            return (x >> bits) | (x << (32 - bits));
        }

        private static void Mix(uint[] s, int a, int b, int c, int d, uint x, uint y)
        {
            unchecked
            {
                s[a] += s[b] + x;
                s[d] = Rotate(s[d] ^ s[a], 16);
                s[c] += s[d];
                s[b] = Rotate(s[b] ^ s[c], 12);
                s[a] += s[b] + y;
                s[d] = Rotate(s[d] ^ s[a], 8);
                s[c] += s[d];
                s[b] = Rotate(s[b] ^ s[c], 7);
            }
        }

        private static uint[] Compress(uint[] cv, uint[] words, ulong counter, uint length, uint flags)
        {
            uint[] s = new uint[16];
            Array.Copy(cv, s, 8);
            Array.Copy(IV, 0, s, 8, 4);
            s[12] = (uint)counter;
            s[13] = (uint)(counter >> 32);
            s[14] = length;
            s[15] = flags;
            uint[] m = (uint[])words.Clone();
            uint[] next = new uint[16];
            for (int round = 0; round < 7; round++)
            {
                Mix(s, 0, 4, 8, 12, m[0], m[1]);
                Mix(s, 1, 5, 9, 13, m[2], m[3]);
                Mix(s, 2, 6, 10, 14, m[4], m[5]);
                Mix(s, 3, 7, 11, 15, m[6], m[7]);
                Mix(s, 0, 5, 10, 15, m[8], m[9]);
                Mix(s, 1, 6, 11, 12, m[10], m[11]);
                Mix(s, 2, 7, 8, 13, m[12], m[13]);
                Mix(s, 3, 4, 9, 14, m[14], m[15]);
                if (round < 6)
                {
                    for (int i = 0; i < 16; i++) next[i] = m[Permutation[i]];
                    uint[] temp = m;
                    m = next;
                    next = temp;
                }
            }
            for (int i = 0; i < 8; i++) s[i] ^= s[i + 8];
            // Only the first eight words are needed for 32-byte hashes and CVs.
            uint[] result = new uint[8];
            Array.Copy(s, result, 8);
            return result;
        }

        private sealed class Output
        {
            public uint[] Cv, Words;
            public ulong Counter;
            public uint Length, Flags;

            public uint[] ChainingValue()
            {
                return Compress(Cv, Words, Counter, Length, Flags);
            }
        }

        private static Output ChunkOutput(byte[] buffer, int length, ulong counter)
        {
            uint[] cv = IV;
            int blocks = Math.Max(1, (length + 63) / 64);
            for (int block = 0; block < blocks; block++)
            {
                int offset = block * 64;
                int count = Math.Min(64, length - offset);
                uint[] words = new uint[16];
                for (int i = 0; i < count; i++)
                    words[i / 4] |= (uint)buffer[offset + i] << (8 * (i % 4));
                uint flags = block == 0 ? ChunkStart : 0;
                if (block == blocks - 1)
                    return new Output { Cv = cv, Words = words, Counter = counter,
                        Length = (uint)count, Flags = flags | ChunkEnd };
                cv = Compress(cv, words, counter, (uint)count, flags);
            }
            throw new InvalidOperationException();
        }

        private static Output ParentOutput(uint[] left, uint[] right)
        {
            uint[] words = new uint[16];
            Array.Copy(left, 0, words, 0, 8);
            Array.Copy(right, 0, words, 8, 8);
            return new Output { Cv = IV, Words = words, Counter = 0, Length = 64, Flags = Parent };
        }

        private static int ReadChunk(Stream input, byte[] buffer)
        {
            int length = 0;
            while (length < buffer.Length)
            {
                int read = input.Read(buffer, length, buffer.Length - length);
                if (read == 0) break;
                length += read;
            }
            return length;
        }

        public static string Hash(Stream input)
        {
            byte[] buffer = new byte[1024];
            Stack<uint[]> stack = new Stack<uint[]>();
            ulong counter = 0;
            Output output = ChunkOutput(buffer, ReadChunk(input, buffer), counter);
            int length;
            while ((length = ReadChunk(input, buffer)) > 0)
            {
                uint[] cv = output.ChainingValue();
                ulong total = ++counter;
                while ((total & 1) == 0)
                {
                    cv = ParentOutput(stack.Pop(), cv).ChainingValue();
                    total >>= 1;
                }
                stack.Push(cv);
                output = ChunkOutput(buffer, length, counter);
            }
            while (stack.Count > 0)
                output = ParentOutput(stack.Pop(), output.ChainingValue());
            uint[] hash = Compress(output.Cv, output.Words, 0, output.Length, output.Flags | Root);
            StringBuilder hex = new StringBuilder(64);
            foreach (uint word in hash)
                for (int i = 0; i < 4; i++)
                    hex.Append(((byte)(word >> (8 * i))).ToString("x2"));
            return hex.ToString();
        }

        public static string HashFile(string path)
        {
            using (FileStream input = new FileStream(path, FileMode.Open, FileAccess.Read,
                FileShare.Read, 4 * 1024 * 1024, FileOptions.SequentialScan))
                return Hash(input);
        }
    }

    public sealed class FileEntry
    {
        public string path;
        public string hash;
        public long size;
    }

    public static class Generator
    {
        public static string FormatJson(string json)
        {
            StringBuilder result = new StringBuilder(json.Length);
            int depth = 0;
            bool inString = false, escaped = false;
            char previous = '\0';
            foreach (char c in json)
            {
                if (inString)
                {
                    result.Append(c);
                    if (escaped) escaped = false;
                    else if (c == '\\') escaped = true;
                    else if (c == '"') inString = false;
                    continue;
                }
                if (Char.IsWhiteSpace(c)) continue;
                bool closing = c == '}' || c == ']';
                bool afterOpening = previous == '{' || previous == '[';
                if (closing) depth--;
                if ((afterOpening && !closing) || previous == ',' || (closing && !afterOpening))
                    result.Append('\n').Append(' ', depth * 2);
                result.Append(c);
                if (c == ':') result.Append(' ');
                if (c == '{' || c == '[') depth++;
                if (c == '"') inString = true;
                previous = c;
            }
            return result.ToString();
        }

        public static FileEntry[] Collect(string directory)
        {
            string root = Path.GetFullPath(directory).TrimEnd(
                Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar) + Path.DirectorySeparatorChar;
            List<FileEntry> entries = new List<FileEntry>();
            foreach (string file in Directory.EnumerateFiles(root, "*", SearchOption.AllDirectories))
            {
                if (Path.GetFileName(file) == ".gitignore") continue;
                entries.Add(new FileEntry { path = file.Substring(root.Length).Replace('\\', '/') });
            }
            entries.Sort(delegate(FileEntry a, FileEntry b) {
                return StringComparer.Ordinal.Compare(a.path, b.path);
            });
            foreach (FileEntry entry in entries)
            {
                Console.WriteLine(entry.path);
                string file = Path.Combine(root, entry.path.Replace('/', Path.DirectorySeparatorChar));
                entry.hash = Blake3.HashFile(file);
                entry.size = new FileInfo(file).Length;
            }
            return entries.ToArray();
        }
    }
}
'@
}

$basePath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($BaseDirectory)
$templatePath = Join-Path $basePath 'index_base.json'
$localizedPath = Join-Path $basePath 'localized_data'
$destination = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputPath)

$index = Get-Content -LiteralPath $templatePath -Raw -Encoding UTF8 | ConvertFrom-Json
if ($null -eq $index -or $index -isnot [System.Management.Automation.PSCustomObject]) {
    throw 'index_base.json must contain a JSON object.'
}
if (-not [System.IO.Directory]::Exists($localizedPath)) {
    Write-Host '[Error] localized_data directory not found'
    return
}

$files = [GenIndex.Generator]::Collect($localizedPath)
$index | Add-Member -MemberType NoteProperty -Name files -Value $files -Force
$json = ConvertTo-Json -InputObject $index -Depth 100 -Compress
$json = [GenIndex.Generator]::FormatJson($json)
[System.IO.File]::WriteAllText($destination, $json, [System.Text.UTF8Encoding]::new($false))
