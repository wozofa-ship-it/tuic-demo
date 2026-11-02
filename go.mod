module tuicdemo

// NOTE: sing-box 1.14.4 的 go directive 未在本地核实（本机无 Go）。
// CI 若报 "requires go >= x.y"，把下面这行改成对应版本即可。
go 1.24

require github.com/sagernet/sing-box v1.14.4

// go.sum 由 CI 的 `go mod tidy` 生成（本机无 Go，无法预生成）。
// 切勿手写 go.sum。
