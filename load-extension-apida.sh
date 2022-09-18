#!/usr/bin/env bash

sqlite3 -cmd '.load zig-out/lib/libapida.so' -json <<EOF
	CREATE VIRTUAL TABLE decoupage_administratif USING apida;
	SELECT * FROM decoupage_administratif WHERE departement_code = 23;
EOF
