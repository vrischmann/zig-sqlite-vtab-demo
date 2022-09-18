#!/usr/bin/env bash

sqlite3 -cmd '.load zig-out/lib/libapida.so' -json <<EOF
	SELECT * FROM apida WHERE departement_code = 23;
EOF
