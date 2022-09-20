#!/usr/bin/env bash

sqlite3 -cmd '.load zig-out/lib/libuser.so' -json <<EOF
	SELECT * FROM user;
EOF
