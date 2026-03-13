# TCP-to-NamedPipe proxy for Docker Desktop on Windows
# Proxies localhost:2375 -> //./pipe/dockerDesktopLinuxEngine
param([int]$Port = 2375)

$pipeName = "dockerDesktopLinuxEngine"
$listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, $Port)
$listener.Start()
Write-Host "[Docker Proxy] Listening on 127.0.0.1:$Port -> \\.\pipe\$pipeName"

while ($true) {
    $client = $listener.AcceptTcpClient()
    $job = Start-Job -ScriptBlock {
        param($clientBytes, $pipeName)
        try {
            $tcpClient = [System.Net.Sockets.TcpClient]::new()
            $tcpClient.Client = [System.Net.Sockets.Socket]::new(
                [System.Net.Sockets.AddressFamily]::InterNetwork,
                [System.Net.Sockets.SocketType]::Stream,
                [System.Net.Sockets.ProtocolType]::Tcp
            )
            # This approach won't work well in a job. Use inline instead.
        } catch { }
    }
    # Actually, let's just use netsh portproxy or similar approach
    $stream = $client.GetStream()
    $pipe = [System.IO.Pipes.NamedPipeClientStream]::new(".", $pipeName, [System.IO.Pipes.PipeDirection]::InOut, [System.IO.Pipes.PipeOptions]::Asynchronous)
    $pipe.Connect(5000)

    # Bidirectional copy
    $buf1 = New-Object byte[] 65536
    $buf2 = New-Object byte[] 65536

    $t1 = [System.Threading.Tasks.Task]::Run({ 
        try {
            while ($true) {
                $n = $stream.Read($buf1, 0, $buf1.Length)
                if ($n -eq 0) { break }
                $pipe.Write($buf1, 0, $n)
                $pipe.Flush()
            }
        } catch { }
    })
    $t2 = [System.Threading.Tasks.Task]::Run({
        try {
            while ($true) {
                $n = $pipe.Read($buf2, 0, $buf2.Length)
                if ($n -eq 0) { break }
                $stream.Write($buf2, 0, $n)
                $stream.Flush()
            }
        } catch { }
    })
    [System.Threading.Tasks.Task]::WaitAny(@($t1, $t2)) | Out-Null
    $pipe.Dispose()
    $client.Close()
}
