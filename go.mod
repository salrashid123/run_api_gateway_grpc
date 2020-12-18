module main

go 1.15

require (
	golang.org/x/net v0.0.0-20201216054612-986b41b23924 // indirect
	google.golang.org/api v0.36.0 // indirect
	google.golang.org/grpc v1.34.0 // indirect
	echo v0.0.0
)

replace "echo" => "./src/echo"