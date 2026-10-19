# Private, short-lived identity probe. The selected build's runtime supplies
# CUDA ordinals; the driver supplies UUIDs, joined by PCI bus, never by ordinal.
param([Parameter(Mandatory=$true)][string]$Runtime)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
try {
Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Text;
using System.Runtime.InteropServices;
public static class VisLlamaCudaIdentity {
    [DllImport("kernel32", CharSet=CharSet.Unicode, ExactSpelling=true, SetLastError=true)]
    static extern IntPtr LoadLibraryW(string path);
    [DllImport("kernel32", CharSet=CharSet.Ansi, ExactSpelling=true)]
    static extern IntPtr GetProcAddress(IntPtr module, string name);
    [UnmanagedFunctionPointer(CallingConvention.Winapi)]
    delegate int Count(out int count);
    [UnmanagedFunctionPointer(CallingConvention.Winapi, CharSet=CharSet.Ansi)]
    delegate int Bus(StringBuilder result, int length, int device);
    [UnmanagedFunctionPointer(CallingConvention.Winapi)]
    delegate int Init(uint flags);
    [UnmanagedFunctionPointer(CallingConvention.Winapi, CharSet=CharSet.Ansi)]
    delegate int ByBus(out int device, string bus);
    [UnmanagedFunctionPointer(CallingConvention.Winapi)]
    delegate int Uuid([Out, MarshalAs(UnmanagedType.LPArray,SizeConst=16)] byte[] uuid, int device);
    static IntPtr Library(string path) {
        IntPtr dll=LoadLibraryW(path);
        if(dll==IntPtr.Zero) throw new Exception("Cannot load " + path + "; Win32 error " + Marshal.GetLastWin32Error());
        return dll;
    }
    static Delegate Function(IntPtr dll, string name, Type type) {
        IntPtr ptr=GetProcAddress(dll,name);
        if(ptr==IntPtr.Zero) throw new Exception("Missing CUDA identity export: " + name);
        return Marshal.GetDelegateForFunctionPointer(ptr,type);
    }
    static void Check(int code, string operation) {
        if(code!=0) throw new Exception(operation + " failed; CUDA error " + code);
    }
    public static string[] Read(string path) {
        // cudaDeviceGetUuid is not a CUDA 12.4 runtime API. Use the documented
        // driver API instead, avoiding cudaDeviceProp's version-dependent ABI.
        IntPtr runtime=Library(path);
        Count count=(Count)Function(runtime,"cudaGetDeviceCount",typeof(Count));
        Bus bus=(Bus)Function(runtime,"cudaDeviceGetPCIBusId",typeof(Bus));
        IntPtr driver=Library(Path.Combine(Environment.SystemDirectory,"nvcuda.dll"));
        Init init=(Init)Function(driver,"cuInit",typeof(Init));
        ByBus byBus=(ByBus)Function(driver,"cuDeviceGetByPCIBusId",typeof(ByBus));
        Uuid uuid=(Uuid)Function(driver,"cuDeviceGetUuid_v2",typeof(Uuid));
        Check(init(0),"cuInit");
        int n; Check(count(out n),"cudaGetDeviceCount");
        if(n<1 || n>64) throw new Exception("CUDA device count outside supported range: " + n);
        string[] result=new string[n];
        for(int i=0;i<n;i++) {
            StringBuilder text=new StringBuilder(64);
            Check(bus(text,64,i),"cudaDeviceGetPCIBusId for CUDA" + i);
            int device; Check(byBus(out device,text.ToString()),"cuDeviceGetByPCIBusId for CUDA" + i);
            byte[] bytes=new byte[16];
            // v2 returns the MIG instance UUID when applicable. Perl rejects
            // any mismatch with the physical UUID reported by nvidia-smi.
            Check(uuid(bytes,device),"cuDeviceGetUuid_v2 for CUDA" + i);
            StringBuilder id=new StringBuilder("GPU-");
            for(int j=0;j<16;j++) {
                if(j==4 || j==6 || j==8 || j==10) id.Append('-');
                id.Append(bytes[j].ToString("x2"));
            }
            result[i]=text.ToString()+"|"+id.ToString();
        }
        return result;
    }
}
'@
# @() prevents PowerShell from unwrapping a single-device result into a scalar.
$bus = @([VisLlamaCudaIdentity]::Read($Runtime))
$rows = @(for($i=0; $i -lt $bus.Count; $i++) { $parts=$bus[$i].Split('|'); @{id="CUDA$i"; bus=$parts[0]; uuid=$parts[1]} })
ConvertTo-Json -InputObject $rows -Compress
} catch {
    # Return details to Perl's private diagnostic path, not stderr/CLIXML or an
    # HTTP response. Include the innermost interop error for actionable logs.
    $detail = $_.Exception
    while($null -ne $detail.InnerException) { $detail = $detail.InnerException }
    ConvertTo-Json -InputObject @{error=$detail.Message} -Compress
    exit 1
}
