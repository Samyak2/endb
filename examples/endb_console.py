#!/usr/bin/env python3

# MIT License

# Copyright (c) 2023-2024 Håkan Råberg and Steven Deobald

# Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

# The above copyright notice and this permission notice (including the next paragraph) shall be included in all copies or substantial portions of the Software.

# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

import cmd
import endb
import pprint
import urllib.error
import re
import time

class EndbConsole(cmd.Cmd):
    def __init__(self, url, accept='application/ld+json', username=None, password=None, prompt='-> '):
        super().__init__()
        self.url = url
        self.accept = accept
        self.username = username
        self.password = password
        self.prompt = prompt
        self.timer = False

    def emptyline(self):
        pass

    def complete_timer(self, text, line, begidx, endidx):
        return [x for x in ['on', 'off'] if x.startswith(text)]

    def do_timer(self, arg):
        'Sets or shows timer.'
        if arg:
            self.timer = arg == 'on'
        if self.timer:
            print('on')
        else:
            print('off')

    def complete_accept(self, text, line, begidx, endidx):
        return [x for x in ['application/json', 'application/ld+json', 'text/csv', 'application/vnd.apache.arrow.file'] if x.startswith(text)]

    def do_accept(self, arg):
        'Sets or shows the accepted mime type.'
        if arg:
            self.accept = re.sub('=\s*', '', arg)
        print(self.accept)

    def do_url(self, arg):
        'Sets or shows the database URL.'
        if arg:
            self.url = re.sub('=\s*', '', arg)
        print(self.url)

    def do_username(self, arg):
        'Sets or shows the database user.'
        if arg:
            self.username = re.sub('=\s*', '', arg)
        print(self.username)

    def do_password(self, arg):
        'Sets the database password.'
        if arg:
            self.password = re.sub('=\s*', '', arg)
        if self.password is not None:
            print('*******')
        else:
            print(None)

    def do_quit(self, arg):
        'Quits the console.'
        return 'stop'

    def default(self, line):
        start_time = None
        if line == 'EOF':
            return 'stop'
        try:
            start_time = time.time()
            result = endb.Endb(self.url, self.accept, self.username, self.password).sql(line)
            if self.accept == 'text/csv':
                print(result.strip())
            elif self.accept == 'application/vnd.apache.arrow.file':
                print(result)
            else:
                pprint.pprint(result)
        except urllib.error.HTTPError as e:
            print('%s %s' % (e.code, e.reason))
            body = e.read().decode()
            if body:
                print(body)
        except urllib.error.URLError as e:
            print(self.url)
            print(e.reason)
        if start_time and self.timer:
            print('Elapsed: %f ms' % (time.time() - start_time))

if __name__ == '__main__':
    import sys
    url = 'http://localhost:3803/sql'
    if len(sys.argv) > 1:
        url = sys.argv[1]
    prompt = '-> '
    if not sys.stdin.isatty():
        prompt = ''
    try:
        EndbConsole(url, prompt=prompt).cmdloop()
        if sys.stdin.isatty():
            print()
    except KeyboardInterrupt:
        print()
