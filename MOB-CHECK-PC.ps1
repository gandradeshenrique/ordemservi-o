<#
  MOB-CHECK PC  -  Teste completo de notebook  (MOBIT SOLUÇÕES)
  ---------------------------------------------------------------
  Fase 1: testes 100% automaticos (CPU, RAM, disco, bateria, rede, BT, GPU, drivers, estresse combinado)
  Fase 2: testes que pedem uma ação fisica (tela, teclado, touchpad, touch, audio, webcam, USB,
          video externo, carregador, tampa, luz do teclado)
  Relatório final: C:\MOB\Relatorios\MOB-CHECK_<serial>_<data>.html

  Parametros:  -Rapido   usa duracoes curtas   |   -Completo  forca o modo completo sem esperar
#>
param([switch]$Rapido,[switch]$Completo)

$ErrorActionPreference = 'Continue'
$ProgressPreference    = 'SilentlyContinue'
$Base   = 'C:\MOB'
$RelDir = "$Base\Relatorios"
New-Item -ItemType Directory -Force -Path $RelDir | Out-Null
$LogFile = "$RelDir\mob-check.log"

# ---------- precisa ser Administrador e STA ----------
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$extra = ''; if($Rapido){$extra+=' -Rapido'}; if($Completo){$extra+=' -Completo'}
if(-not $isAdmin){
    Start-Process powershell -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -STA -File `"$PSCommandPath`"$extra"
    exit
}
if([Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA'){
    Start-Process powershell -ArgumentList "-NoProfile -ExecutionPolicy Bypass -STA -File `"$PSCommandPath`"$extra"
    exit
}
$script:Mutex = New-Object Threading.Mutex($false,'Global\MOBCHECKPC')
if(-not $script:Mutex.WaitOne(0)){ exit }

Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase,System.Windows.Forms,System.Drawing

# ---------- codigo nativo (C#) para estresse, audio e tampa ----------
Add-Type -ReferencedAssemblies 'PresentationCore','WindowsBase' -TypeDefinition @'
using System;
using System.IO;
using System.Text;
using System.Threading;
using System.Diagnostics;
using System.Collections.Generic;
using System.Runtime.InteropServices;

public static class MobNative {
    [DllImport("winmm.dll", CharSet=CharSet.Auto)] public static extern int mciSendString(string cmd, StringBuilder ret, int retLen, IntPtr hwnd);
    [DllImport("winmm.dll", CharSet=CharSet.Auto)] public static extern bool mciGetErrorString(int err, StringBuilder buf, int len);
    [DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, int flags, int extra);
    [DllImport("user32.dll")] public static extern IntPtr RegisterPowerSettingNotification(IntPtr h, ref Guid g, int flags);
    [DllImport("kernel32.dll")] public static extern uint SetThreadExecutionState(uint f);
    public static void VolumeMax(){ for(int i=0;i<52;i++){ keybd_event(0xAF,0,0,0); keybd_event(0xAF,0,2,0);} }
}

public class CpuStress {
    public volatile bool Stop; public long Ops; public long Errors; Thread[] ts;
    public void Start(int n){
        ts=new Thread[n];
        for(int i=0;i<n;i++){ ts[i]=new Thread(Work); ts[i].IsBackground=true; ts[i].Priority=ThreadPriority.Normal; ts[i].Start(); }
    }
    void Work(){
        ulong expected=Compute();
        while(!Stop){ ulong r=Compute(); Interlocked.Increment(ref Ops); if(r!=expected) Interlocked.Increment(ref Errors); }
    }
    static ulong Compute(){
        ulong h=1469598103934665603UL;
        double a0=1.0,a1=1.1,a2=1.2,a3=1.3,a4=1.4,a5=1.5,a6=1.6,a7=1.7;
        for(int i=1;i<400000;i++){
            a0=a0*1.0000001+0.5; a1=a1*1.0000002+0.4; a2=a2*1.0000003+0.3; a3=a3*1.0000004+0.2;
            a4=a4*1.0000005+0.1; a5=a5*1.0000006+0.6; a6=a6*1.0000007+0.7; a7=a7*1.0000008+0.8;
            if((i&7)==0){ a0+=Math.Sqrt(a1); a2+=Math.Sin(a3); a4+=Math.Sqrt(a5); a6+=Math.Cos(a7); }
            h^=(ulong)i; h*=1099511628211UL; h^=(h>>29);
            if(a0>1e12){ a0=1.0; a1=1.1; a2=1.2; a3=1.3; a4=1.4; a5=1.5; a6=1.6; a7=1.7; }
        }
        return h ^ (ulong)BitConverter.DoubleToInt64Bits(a0+a1+a2+a3+a4+a5+a6+a7);
    }
    public void Join(){ foreach(var t in ts) t.Join(); }
}

// Teste de RAM em paralelo (todos os nucleos): rapido e sem falso positivo.
// Errors = divergencia real de dados. Err = problema do teste (ex.: sem memoria livre) - NAO e defeito de RAM.
public class RamTest {
    public long Tested; public long Errors; public string Err = ""; public volatile int Pct; public volatile bool Done; public volatile bool Cancel;
    public void RunAsync(long target, int loops) { var t = new Thread(() => Run(target, loops)); t.IsBackground = true; t.Start(); }
    static void Each(List<long[]> list, Action<int> body) { System.Threading.Tasks.Parallel.For(0, list.Count, body); }
    void Run(long target, int loops) {
        var list = new List<long[]>();
        try {
            GC.Collect(); GC.WaitForPendingFinalizers(); GC.Collect();
            const int CH = 8 * 1024 * 1024;            // 64 MB por bloco
            long n = target / (CH * 8L); if (n < 1) n = 1;
            for (long i = 0; i < n && !Cancel; i++) { try { list.Add(new long[CH]); } catch (OutOfMemoryException) { break; } }
            Tested = (long)list.Count * CH * 8;
            if (list.Count == 0) { Err = "Nao foi possivel reservar memoria para o teste"; return; }
            long[] pats = { unchecked((long)0xAAAAAAAAAAAAAAAAUL), 0x5555555555555555L, 0L, -1L };
            long mul = unchecked((long)0x9E3779B97F4A7C15UL);
            int steps = loops * (pats.Length + 2); int step = 0;
            for (int l = 0; l < loops && !Cancel; l++) {
                foreach (var p in pats) {
                    if (Cancel) break;
                    Each(list, c => { var a = list[c]; for (int i = 0; i < a.Length; i++) a[i] = p; });
                    Each(list, c => { var a = list[c]; long e = 0; for (int i = 0; i < a.Length; i++) if (a[i] != p) e++; if (e > 0) Interlocked.Add(ref Errors, e); });
                    step++; Pct = Math.Min(100, step * 100 / steps);
                }
                if (Cancel) break;
                Each(list, c => { var a = list[c]; long b = (long)c * a.Length; for (int i = 0; i < a.Length; i++) a[i] = unchecked((b + i) * mul); });
                Each(list, c => { var a = list[c]; long b = (long)c * a.Length; long e = 0; for (int i = 0; i < a.Length; i++) if (a[i] != unchecked((b + i) * mul)) e++; if (e > 0) Interlocked.Add(ref Errors, e); });
                step++; Pct = Math.Min(100, step * 100 / steps);
                if (Cancel) break;
                Each(list, c => { var a = list[c]; ulong x = 88172645463325252UL ^ (ulong)(c + 1) * 0x9E3779B97F4A7C15UL; for (int i = 0; i < a.Length; i++) { x ^= x << 13; x ^= x >> 7; x ^= x << 17; a[i] = (long)x; } });
                Each(list, c => { var a = list[c]; ulong x = 88172645463325252UL ^ (ulong)(c + 1) * 0x9E3779B97F4A7C15UL; long e = 0; for (int i = 0; i < a.Length; i++) { x ^= x << 13; x ^= x >> 7; x ^= x << 17; if (a[i] != (long)x) e++; } if (e > 0) Interlocked.Add(ref Errors, e); });
                step++; Pct = Math.Min(100, step * 100 / steps);
            }
        } catch (Exception e) { Err = e.GetType().Name + ": " + e.Message; }
        finally { list.Clear(); list = null; GC.Collect(); Done = true; }
    }
}

public class DiskTest {
    public double WriteMBs; public double ReadMBs; public long Errors; public string Err=""; public volatile int Pct; public volatile bool Done; public volatile bool Cancel;
    public void RunAsync(string path,long bytes,bool loop){ var t=new Thread(()=>Run(path,bytes,loop)); t.IsBackground=true; t.Start(); }
    void Run(string path,long bytes,bool loop){
        try{
            byte[] buf=new byte[4*1024*1024]; new Random(42).NextBytes(buf);
            byte[] rb=new byte[buf.Length];
            do{
                var sw=Stopwatch.StartNew();
                using(var fs=new FileStream(path,FileMode.Create,FileAccess.Write,FileShare.None,1<<20,FileOptions.WriteThrough)){
                    long w=0; while(w<bytes && !Cancel){ fs.Write(buf,0,buf.Length); w+=buf.Length; Pct=(int)(w*50/bytes); }
                    fs.Flush(true);
                }
                sw.Stop(); WriteMBs=(bytes/1048576.0)/Math.Max(0.001,sw.Elapsed.TotalSeconds);
                var sr=Stopwatch.StartNew(); long r=0;
                using(var fs=new FileStream(path,FileMode.Open,FileAccess.Read,FileShare.None,1<<20,FileOptions.SequentialScan)){
                    int n; while((n=fs.Read(rb,0,rb.Length))>0 && !Cancel){
                        r+=n;
                        for(int i=0;i<n;i++){ if(rb[i]!=buf[i]){ Errors++; break; } }
                        Pct=50+(int)(r*50/bytes);
                    }
                }
                sr.Stop(); ReadMBs=(r/1048576.0)/Math.Max(0.001,sr.Elapsed.TotalSeconds);
                try{ File.Delete(path); }catch(Exception){}
            }while(loop && !Cancel);
        }catch(Exception e){ Err=e.Message; }
        Done=true;
    }
}

public static class WavTool {
    public static double[] Level(string path){
        byte[] b=File.ReadAllBytes(path); int pos=12; int bits=16; int dataPos=-1,dataLen=0;
        while(pos+8<=b.Length){
            string id=Encoding.ASCII.GetString(b,pos,4); int len=BitConverter.ToInt32(b,pos+4);
            if(id=="fmt "){ bits=BitConverter.ToInt16(b,pos+22); }
            if(id=="data"){ dataPos=pos+8; dataLen=Math.Min(len,b.Length-dataPos); break; }
            pos+=8+len+(len&1);
        }
        if(dataPos<0) return new double[]{0,0};
        double sum=0,peak=0; int cnt=0;
        if(bits==16){ for(int i=dataPos;i+1<dataPos+dataLen;i+=2){ double v=BitConverter.ToInt16(b,i)/32768.0; sum+=v*v; if(Math.Abs(v)>peak)peak=Math.Abs(v); cnt++; } }
        else { for(int i=dataPos;i<dataPos+dataLen;i++){ double v=(b[i]-128)/128.0; sum+=v*v; if(Math.Abs(v)>peak)peak=Math.Abs(v); cnt++; } }
        return new double[]{ cnt>0?Math.Sqrt(sum/cnt):0, peak };
    }
    // channel: 0 = ambos, 1 = esquerdo, 2 = direito
    public static void WriteTone(string path,double freq,double secs,int channel){
        int sr=44100; int n=(int)(sr*secs);
        using(var fs=new FileStream(path,FileMode.Create)) using(var w=new BinaryWriter(fs)){
            w.Write(Encoding.ASCII.GetBytes("RIFF")); w.Write(36+n*4); w.Write(Encoding.ASCII.GetBytes("WAVEfmt "));
            w.Write(16); w.Write((short)1); w.Write((short)2); w.Write(sr); w.Write(sr*4); w.Write((short)4); w.Write((short)16);
            w.Write(Encoding.ASCII.GetBytes("data")); w.Write(n*4);
            for(int i=0;i<n;i++){
                double fade=Math.Min(1.0,Math.Min(i,n-i)/2000.0);
                short s=(short)(Math.Sin(2*Math.PI*freq*i/sr)*0.8*32767*fade);
                w.Write((short)(channel==2?0:s)); w.Write((short)(channel==1?0:s));
            }
        }
    }
}

public class LidMonitor {
    public int State=-1; public int Closed; public int Opened; IntPtr reg=IntPtr.Zero;
    static readonly Guid G=new Guid("BA3E0F4D-B817-4094-A2D1-D56379E6A0F3");
    public System.Windows.Interop.HwndSourceHook GetHook(){ return new System.Windows.Interop.HwndSourceHook(Hook); }
    public bool Register(IntPtr h){ Guid g=G; reg=MobNative.RegisterPowerSettingNotification(h,ref g,0); return reg!=IntPtr.Zero; }
    IntPtr Hook(IntPtr hwnd,int msg,IntPtr wp,IntPtr lp,ref bool handled){
        if(msg==0x218 && wp.ToInt32()==0x8013){
            Guid g=(Guid)Marshal.PtrToStructure(lp,typeof(Guid));
            if(g==G){ int v=Marshal.ReadByte(lp,20); State=v; if(v==0) Closed++; else Opened++; }
        }
        return IntPtr.Zero;
    }
}

// Contadores de desempenho pelo nome em INGLES (funciona no Windows em portugues)
public class Pdh : IDisposable {
    [DllImport("pdh.dll", CharSet = CharSet.Unicode)] static extern int PdhOpenQuery(string src, IntPtr user, out IntPtr q);
    [DllImport("pdh.dll", CharSet = CharSet.Unicode)] static extern int PdhAddEnglishCounter(IntPtr q, string path, IntPtr user, out IntPtr c);
    [DllImport("pdh.dll")] static extern int PdhCollectQueryData(IntPtr q);
    [DllImport("pdh.dll")] static extern int PdhGetFormattedCounterValue(IntPtr c, uint fmt, IntPtr type, out FMT v);
    [DllImport("pdh.dll", CharSet = CharSet.Unicode)] static extern int PdhGetFormattedCounterArray(IntPtr c, uint fmt, ref uint size, out uint count, IntPtr buf);
    [DllImport("pdh.dll")] static extern int PdhCloseQuery(IntPtr q);
    [StructLayout(LayoutKind.Explicit)] struct FMT { [FieldOffset(0)] public uint CStatus; [FieldOffset(8)] public double d; }
    const uint DBL = 0x200 | 0x8000; // PDH_FMT_DOUBLE | PDH_FMT_NOCAP100
    IntPtr q = IntPtr.Zero; List<IntPtr> cs = new List<IntPtr>();
    public Pdh() { try { if (PdhOpenQuery(null, IntPtr.Zero, out q) != 0) q = IntPtr.Zero; } catch { q = IntPtr.Zero; } }
    public int Add(string path) { if (q == IntPtr.Zero) return -1; IntPtr c; try { if (PdhAddEnglishCounter(q, path, IntPtr.Zero, out c) != 0) return -1; } catch { return -1; } cs.Add(c); return cs.Count - 1; }
    public void Collect() { if (q != IntPtr.Zero) try { PdhCollectQueryData(q); } catch { } }
    public double Get(int i) { if (i < 0) return double.NaN; FMT v; try { if (PdhGetFormattedCounterValue(cs[i], DBL, IntPtr.Zero, out v) != 0 || v.CStatus > 1) return double.NaN; return v.d; } catch { return double.NaN; } }
    // maior valor entre as instancias de um contador com (*)
    public double Max(int i) {
        if (i < 0) return double.NaN;
        try {
            uint size = 0, count;
            PdhGetFormattedCounterArray(cs[i], DBL, ref size, out count, IntPtr.Zero);
            if (size == 0) return double.NaN;
            IntPtr buf = Marshal.AllocHGlobal((int)size);
            try {
                if (PdhGetFormattedCounterArray(cs[i], DBL, ref size, out count, buf) != 0) return double.NaN;
                double m = double.NaN;
                for (int k = 0; k < count; k++) {
                    IntPtr it = new IntPtr(buf.ToInt64() + k * 24);
                    uint st = (uint)Marshal.ReadInt32(new IntPtr(it.ToInt64() + 8));
                    double d = BitConverter.Int64BitsToDouble(Marshal.ReadInt64(new IntPtr(it.ToInt64() + 16)));
                    if (st <= 1 && (double.IsNaN(m) || d > m)) m = d;
                }
                return m;
            } finally { Marshal.FreeHGlobal(buf); }
        } catch { return double.NaN; }
    }
    public void Dispose() { if (q != IntPtr.Zero) { try { PdhCloseQuery(q); } catch { } q = IntPtr.Zero; } }
}

// Audio do Windows (Core Audio): conta saidas/entradas ativas e coloca volume 100% sem mudo
[ComImport, Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")] class MMDeviceEnumeratorCo { }
[ComImport, Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IMMDeviceEnumerator { [PreserveSig] int EnumAudioEndpoints(int flow, int mask, out IMMDeviceCollection d); [PreserveSig] int GetDefaultAudioEndpoint(int flow, int role, out IMMDevice d); }
[ComImport, Guid("0BD7A1BE-7A1A-44DB-8397-CC5392387B5E"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IMMDeviceCollection { [PreserveSig] int GetCount(out int n); [PreserveSig] int Item(int i, out IMMDevice d); }
[ComImport, Guid("D666063F-1587-4E43-81F1-B948E807363F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IMMDevice { [PreserveSig] int Activate(ref Guid iid, int ctx, IntPtr p, [MarshalAs(UnmanagedType.IUnknown)] out object o); }
[ComImport, Guid("5CDF2C82-841E-4546-9722-0CF74078229A"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IAudioEndpointVolume {
    [PreserveSig] int RegisterControlChangeNotify(IntPtr p); [PreserveSig] int UnregisterControlChangeNotify(IntPtr p);
    [PreserveSig] int GetChannelCount(out uint c); [PreserveSig] int SetMasterVolumeLevel(float db, ref Guid ctx);
    [PreserveSig] int SetMasterVolumeLevelScalar(float v, ref Guid ctx); [PreserveSig] int GetMasterVolumeLevel(out float db);
    [PreserveSig] int GetMasterVolumeLevelScalar(out float v); [PreserveSig] int SetChannelVolumeLevel(uint ch, float db, ref Guid ctx);
    [PreserveSig] int SetChannelVolumeLevelScalar(uint ch, float v, ref Guid ctx); [PreserveSig] int GetChannelVolumeLevel(uint ch, out float db);
    [PreserveSig] int GetChannelVolumeLevelScalar(uint ch, out float v); [PreserveSig] int SetMute([MarshalAs(UnmanagedType.Bool)] bool m, ref Guid ctx);
    [PreserveSig] int GetMute([MarshalAs(UnmanagedType.Bool)] out bool m);
}
public static class MobAudio {
    // flow: 0 = saida (alto-falante), 1 = entrada (microfone)
    public static int Count(int flow) {
        try { var e = (IMMDeviceEnumerator)(new MMDeviceEnumeratorCo()); IMMDeviceCollection c; if (e.EnumAudioEndpoints(flow, 1, out c) != 0) return 0; int n; c.GetCount(out n); return n; } catch { return -1; }
    }
    // volume maximo, sem mudo, canais equilibrados no dispositivo padrao. Retorna texto do que fez.
    public static string Max(int flow) {
        try {
            var e = (IMMDeviceEnumerator)(new MMDeviceEnumeratorCo()); IMMDevice d;
            if (e.GetDefaultAudioEndpoint(flow, 1, out d) != 0 || d == null) return "sem dispositivo padrao";
            Guid iid = typeof(IAudioEndpointVolume).GUID; object o;
            if (d.Activate(ref iid, 23, IntPtr.Zero, out o) != 0) return "nao foi possivel abrir o controle de volume";
            var v = (IAudioEndpointVolume)o; Guid z = Guid.Empty;
            v.SetMute(false, ref z); v.SetMasterVolumeLevelScalar(1.0f, ref z);
            uint ch; v.GetChannelCount(out ch); for (uint i = 0; i < ch; i++) v.SetChannelVolumeLevelScalar(i, 1.0f, ref z);
            float lv; bool mu; v.GetMasterVolumeLevelScalar(out lv); v.GetMute(out mu);
            return string.Format("volume {0:0}%{1}, {2} canal(is)", lv * 100, mu ? " (MUDO)" : "", ch);
        } catch (Exception ex) { return "erro: " + ex.Message; }
    }
}

'@

# mantem a maquina acordada durante todo o teste
[void][MobNative]::SetThreadExecutionState([uint32]2147483651)   # ES_CONTINUOUS|ES_SYSTEM_REQUIRED|ES_DISPLAY_REQUIRED (0x80000003 vira numero negativo no PowerShell)

# ---------- janela principal (WPF) ----------
$LogoB64='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'
[xml]$XAML = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="MOB-CHECK PC - MOBIT Soluções" WindowStyle="None" WindowState="Maximized" ResizeMode="NoResize"
        Background="#06101E" Foreground="#EAF2FF" FontFamily="Segoe UI">
  <Window.Resources>
    <Style x:Key="Btn" TargetType="Button">
      <Setter Property="Foreground" Value="White"/><Setter Property="Background" Value="#16304F"/>
      <Setter Property="FontSize" Value="17"/><Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Padding" Value="26,12"/><Setter Property="Margin" Value="7,0"/><Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template"><Setter.Value>
        <ControlTemplate TargetType="Button">
          <Border x:Name="bd" Background="{TemplateBinding Background}" CornerRadius="10" Padding="{TemplateBinding Padding}">
            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
          </Border>
          <ControlTemplate.Triggers>
            <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="bd" Property="Opacity" Value="0.85"/></Trigger>
            <Trigger Property="IsPressed" Value="True"><Setter TargetName="bd" Property="Opacity" Value="0.7"/></Trigger>
          </ControlTemplate.Triggers>
        </ControlTemplate>
      </Setter.Value></Setter>
    </Style>
  </Window.Resources>
  <Grid>
    <Grid.Background>
      <RadialGradientBrush Center="0.6,0.45" RadiusX="0.8" RadiusY="0.9" GradientOrigin="0.6,0.45">
        <GradientStop Color="#0C2444" Offset="0"/><GradientStop Color="#06101E" Offset="1"/>
      </RadialGradientBrush>
    </Grid.Background>
    <Grid.RowDefinitions>
      <RowDefinition Height="78"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>
    <Border Grid.Row="0" Background="#051222" BorderBrush="#1E8BFF" BorderThickness="0,0,0,2">
      <Grid Margin="18,0">
        <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
          <Image x:Name="Logo" Height="62" Stretch="Uniform" RenderOptions.BitmapScalingMode="HighQuality"/>
          <Border Width="2" Background="#1E8BFF" Margin="18,10" Opacity="0.7"/>
          <StackPanel VerticalAlignment="Center">
            <TextBlock FontSize="22" FontWeight="Bold"><Run Text="MOB-CHECK" Foreground="#FFFFFF"/><Run Text=" PC" Foreground="#35B6FF"/></TextBlock>
            <TextBlock x:Name="Sub" FontSize="13" Foreground="#8FA6C3" Text="Diagnóstico completo de notebook"/>
          </StackPanel>
        </StackPanel>
        <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Center">
          <StackPanel VerticalAlignment="Center" Margin="0,0,22,0">
            <TextBlock x:Name="Resumo" FontSize="15" Foreground="#EAF2FF" HorizontalAlignment="Right"/>
            <ProgressBar x:Name="Geral" Width="220" Height="6" Margin="0,6,0,0" Minimum="0" Maximum="100" Foreground="#35B6FF" Background="#16304F" BorderThickness="0"/>
          </StackPanel>
          <Button x:Name="BtnSair" Content="Sair" Style="{StaticResource Btn}" FontSize="14" Padding="16,6"/>
        </StackPanel>
      </Grid>
    </Border>
    <Grid Grid.Row="1">
      <Grid.ColumnDefinitions><ColumnDefinition Width="340"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
      <Border Grid.Column="0" Background="#B3081629" BorderBrush="#17345A" BorderThickness="0,0,1,0">
        <ScrollViewer VerticalScrollBarVisibility="Auto"><StackPanel x:Name="Lista" Margin="18,10"/></ScrollViewer>
      </Border>
      <Grid Grid.Column="1" Margin="30,20,30,8">
        <Grid.RowDefinitions>
          <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/>
          <RowDefinition Height="*"/><RowDefinition Height="96"/>
        </Grid.RowDefinitions>
        <TextBlock x:Name="Titulo" Grid.Row="0" FontSize="30" FontWeight="Bold" Foreground="#FFFFFF"/>
        <TextBlock x:Name="InstrTxt" Grid.Row="1" FontSize="17" Foreground="#A9BCD6" TextWrapping="Wrap" Margin="0,6,0,12"/>
        <ProgressBar x:Name="Barra" Grid.Row="2" Height="8" Minimum="0" Maximum="100" Foreground="#1E8BFF" Background="#16304F" BorderThickness="0" Margin="0,0,0,14"/>
        <Border Grid.Row="3" Background="#990B1A2E" BorderBrush="#17345A" BorderThickness="1" CornerRadius="14" Padding="18">
          <ContentControl x:Name="Painel"/>
        </Border>
        <TextBox x:Name="LogBox" Grid.Row="4" IsReadOnly="True" Background="#05101E" Foreground="#6F86A3" BorderBrush="#17345A"
                 FontFamily="Consolas" FontSize="12" VerticalScrollBarVisibility="Auto" TextWrapping="NoWrap" Margin="0,10,0,0"/>
      </Grid>
    </Grid>
    <Border Grid.Row="2" Background="#051222" BorderBrush="#17345A" BorderThickness="0,1,0,0" MinHeight="76">
      <StackPanel x:Name="Botoes" Orientation="Horizontal" HorizontalAlignment="Center" VerticalAlignment="Center" Margin="0,10"/>
    </Border>
  </Grid>
</Window>
'@
$Win = [Windows.Markup.XamlReader]::Load((New-Object Xml.XmlNodeReader $XAML))
foreach($n in 'Sub','Resumo','BtnSair','Lista','Titulo','InstrTxt','Barra','Painel','LogBox','Botoes','Logo','Geral'){ Set-Variable -Name "ui_$n" -Value $Win.FindName($n) -Scope Script }
function Get-LogoImage {
    $bytes=[Convert]::FromBase64String($LogoB64); $ms=New-Object IO.MemoryStream(,$bytes)
    $bi=New-Object Windows.Media.Imaging.BitmapImage; $bi.BeginInit(); $bi.CacheOption='OnLoad'; $bi.StreamSource=$ms; $bi.EndInit(); $bi.Freeze(); return $bi
}
try{ $ui_Logo.Source=Get-LogoImage }catch{}

$Cor    = @{ OK='#2EE59D'; ALERTA='#FFC247'; FALHA='#FF5C6C'; PULADO='#6F8199'; RODANDO='#35B6FF'; PENDENTE='#4A5F7A' }
$Icone  = @{ OK=[string][char]0x2714; ALERTA=[string][char]0x26A0; FALHA=[string][char]0x2718; PULADO='-'; RODANDO=[string][char]0x25B6; PENDENTE=[string][char]0x25CB }
function Br([string]$hex){ (New-Object Windows.Media.BrushConverter).ConvertFromString($hex) }

function UI-Pump { try{ $Win.Dispatcher.Invoke([Action]{}, [Windows.Threading.DispatcherPriority]::Background) }catch{} }
function Wait-UI([int]$ms){ $sw=[Diagnostics.Stopwatch]::StartNew(); while($sw.ElapsedMilliseconds -lt $ms){ UI-Pump; Start-Sleep -Milliseconds 25 } }
function Log([string]$m){
    $t=(Get-Date).ToString('HH:mm:ss')+'  '+$m
    $ui_LogBox.AppendText($t+"`r`n"); $ui_LogBox.ScrollToEnd()
    try{ Add-Content -Path $LogFile -Value $t -ErrorAction SilentlyContinue }catch{}
    UI-Pump
}
function Set-Screen([string]$titulo,[string]$instr){
    $ui_Titulo.Text=$titulo; $ui_InstrTxt.Text=$instr; $ui_Painel.Content=$null; $ui_Barra.Value=0; $script:KeyHook=$null; UI-Pump
}
function Live([string]$txt,[int]$size=22){
    if(-not ($ui_Painel.Content -is [Windows.Controls.TextBlock])){
        $tb=New-Object Windows.Controls.TextBlock; $tb.FontSize=$size; $tb.Foreground=(Br '#E8EDF2'); $tb.TextWrapping='Wrap'; $tb.FontFamily='Consolas'
        $ui_Painel.Content=$tb
    }
    $ui_Painel.Content.Text=$txt; UI-Pump
}

# ---------- lista de testes ----------
$Tests = New-Object System.Collections.ArrayList
function Add-T($id,$nome,$fase){ [void]$Tests.Add([pscustomobject]@{Id=$id;Nome=$nome;Fase=$fase;Status='PENDENTE';Detalhe='';Seg=0}) }
function Get-T($id){ $Tests | Where-Object { $_.Id -eq $id } | Select-Object -First 1 }
function Refresh-List {
    $ui_Lista.Children.Clear()
    $lastFase=0
    foreach($t in $Tests){
        if($t.Fase -ne $lastFase){
            $h=New-Object Windows.Controls.TextBlock; $h.FontSize=12; $h.Foreground=(Br '#35B6FF'); $h.FontWeight='Bold'; $h.Margin='0,14,0,6'
            $h.Text= if($t.Fase -eq 1){'FASE 1 - AUTOMÁTICA'}else{'FASE 2 - COM VOCÊ'}
            [void]$ui_Lista.Children.Add($h); $lastFase=$t.Fase
        }
        $r=New-Object Windows.Controls.TextBlock; $r.FontSize=15; $r.Margin='0,3,0,3'
        $r.Text=("{0}  {1}" -f $Icone[$t.Status],$t.Nome); $r.Foreground=(Br $Cor[$t.Status])
        if($t.Status -eq 'RODANDO'){ $r.FontWeight='Bold' }
        [void]$ui_Lista.Children.Add($r)
    }
    $feitos=@($Tests | Where-Object { $_.Status -notin 'PENDENTE','RODANDO' }).Count
    $ui_Resumo.Text="$feitos de $($Tests.Count) testes concluídos"; $ui_Geral.Value=100*$feitos/[math]::Max(1,$Tests.Count)
    UI-Pump
}
function Set-T($id,$status,$detalhe){
    $t=Get-T $id; $t.Status=$status; $t.Detalhe=[string]$detalhe
    Log ("[{0}] {1}: {2}" -f $status,$t.Nome,$detalhe)
    Refresh-List
}

# ---------- botões e espera ----------
$script:Clicked=$null
function Show-Buttons([string[]]$labels){
    $ui_Botoes.Children.Clear(); $script:Clicked=$null
    $i=0
    foreach($l in $labels){
        $b=New-Object Windows.Controls.Button
        $b.Style=$Win.Resources['Btn']; $b.Content=$l; $b.MinWidth=160
        $b.Background=(Br $(if($i -eq 0){'#1E8BFF'}else{'#16304F'}))
        $b.Add_Click({ param($s,$e) $script:Clicked=[string]$s.Content })
        [void]$ui_Botoes.Children.Add($b); $i++
    }
    UI-Pump
}
function Clear-Buttons { $ui_Botoes.Children.Clear(); $script:Clicked=$null; UI-Pump }
function Wait-Click([string[]]$labels,[int]$timeoutSec=0){
    Show-Buttons $labels
    $sw=[Diagnostics.Stopwatch]::StartNew()
    while($null -eq $script:Clicked){
        UI-Pump; Start-Sleep -Milliseconds 30
        if($timeoutSec -gt 0 -and $sw.Elapsed.TotalSeconds -gt $timeoutSec){ Clear-Buttons; return $null }
    }
    $c=$script:Clicked; Clear-Buttons; return $c
}

function Run-T($id,[scriptblock]$sb){
    $t=Get-T $id; $t.Status='RODANDO'; Refresh-List; $ui_Barra.Value=0
    $sw=[Diagnostics.Stopwatch]::StartNew()
    try{ & $sb }catch{ $msg=('Erro interno do teste: '+$_.Exception.Message+' (linha '+$_.InvocationInfo.ScriptLineNumber+')'); Log ($msg+' | '+$_.ScriptStackTrace); Set-T $id 'ALERTA' ('Teste não concluído por erro do programa (não indica defeito): '+$_.Exception.Message) }
    $t.Seg=[int]$sw.Elapsed.TotalSeconds
    if($t.Status -eq 'RODANDO'){ Set-T $id 'ALERTA' 'O teste terminou sem resultado' }
    Clear-Buttons; $script:KeyHook=$null
}

# ---------- utilitarios de hardware ----------
# ---------- sensores: temperatura e carga da CPU (sem baixar nada, funciona em Windows pt-BR) ----------
$script:Perf=$null
function Start-Perf {
    if($script:Perf){ return }
    $p=New-Object Pdh
    $script:PerfIdx=@{
        Util  = $p.Add('\Processor Information(_Total)\% Processor Utility')
        Time  = $p.Add('\Processor Information(_Total)\% Processor Time')
        Perf  = $p.Add('\Processor Information(_Total)\% Processor Performance')
        Therm = $p.Add('\Thermal Zone Information(*)\Temperature')
        ThermH= $p.Add('\Thermal Zone Information(*)\High Precision Temperature')
    }
    $p.Collect(); $script:Perf=$p
}
# devolve @{Carga; Desemp; Temp} - chame no maximo 1x por segundo
function Read-Perf {
    Start-Perf; $p=$script:Perf; $i=$script:PerfIdx; $p.Collect()
    $carga=$p.Get($i.Util); if([double]::IsNaN($carga)){ $carga=$p.Get($i.Time) }
    if(-not [double]::IsNaN($carga)){ $carga=[math]::Min(100,[math]::Max(0,$carga)) }
    $temp=$null
    $k=$p.Max($i.ThermH); if(-not [double]::IsNaN($k) -and $k -gt 2000){ $temp=$k/10-273.15 }
    if($null -eq $temp){ $k=$p.Max($i.Therm); if(-not [double]::IsNaN($k) -and $k -gt 200){ $temp=$k-273.15 } }
    if($null -eq $temp -or $temp -lt 10 -or $temp -gt 125){
        $temp=$null
        if(-not $script:AcpiFail){
            try{ $z=@(Get-CimInstance -Namespace root/wmi -ClassName MSAcpi_ThermalZoneTemperature -ErrorAction Stop | ForEach-Object { ($_.CurrentTemperature/10)-273.15 } | Where-Object { $_ -gt 10 -and $_ -lt 125 })
                 if($z.Count){ $temp=($z | Measure-Object -Maximum).Maximum } else { $script:AcpiFail=$true } }catch{ $script:AcpiFail=$true }
        }
    }
    return [pscustomobject]@{ Carga=$carga; Desemp=$p.Get($i.Perf); Temp=$(if($null -ne $temp){[math]::Round($temp,0)}else{$null}) }
}
function Get-CpuTemp { (Read-Perf).Temp }

# ---------- grafico ao vivo (WPF) ----------
function New-LiveChart([string[]]$nomes,[string[]]$cores,[double]$ymax=100){
    $g=New-Object Windows.Controls.Grid
    $g.RowDefinitions.Add((New-Object Windows.Controls.RowDefinition -Property @{Height='Auto'}))
    $g.RowDefinitions.Add((New-Object Windows.Controls.RowDefinition -Property @{Height='Auto'}))
    $g.RowDefinitions.Add((New-Object Windows.Controls.RowDefinition -Property @{Height='*'}))
    $tiles=New-Object Windows.Controls.Primitives.UniformGrid; $tiles.Rows=1; $tiles.Margin='0,0,0,12'
    [Windows.Controls.Grid]::SetRow($tiles,0); [void]$g.Children.Add($tiles)
    $leg=New-Object Windows.Controls.StackPanel; $leg.Orientation='Horizontal'; $leg.Margin='0,0,0,6'
    [Windows.Controls.Grid]::SetRow($leg,1); [void]$g.Children.Add($leg)
    $cv=New-Object Windows.Controls.Canvas; $cv.ClipToBounds=$true; $cv.Background=(Br '#07162A'); $cv.MinHeight=180
    [Windows.Controls.Grid]::SetRow($cv,2); [void]$g.Children.Add($cv)
    $ch=[pscustomobject]@{ Grid=$g; Tiles=$tiles; Canvas=$cv; Series=@(); Ymax=$ymax; Pontos=120; TileTxt=@{} }
    for($k=0;$k -lt $nomes.Count;$k++){
        $pl=New-Object Windows.Shapes.Polyline; $pl.Stroke=(Br $cores[$k]); $pl.StrokeThickness=3; $pl.StrokeLineJoin='Round'
        [void]$cv.Children.Add($pl)
        $ch.Series+=[pscustomobject]@{ Nome=$nomes[$k]; Line=$pl; Vals=(New-Object System.Collections.ArrayList) }
        $dot=New-Object Windows.Controls.TextBlock; $dot.Text=([string][char]0x25A0)+' '+$nomes[$k]+'    '; $dot.Foreground=(Br $cores[$k]); $dot.FontSize=13
        [void]$leg.Children.Add($dot)
    }
    return $ch
}
function Add-Tile($ch,[string]$id,[string]$rotulo,[string]$cor){
    $b=New-Object Windows.Controls.Border; $b.Background=(Br '#0E2138'); $b.CornerRadius='12'; $b.Margin='0,0,10,0'; $b.Padding='16,10'; $b.BorderBrush=(Br '#17345A'); $b.BorderThickness='1'
    $sp=New-Object Windows.Controls.StackPanel
    $t1=New-Object Windows.Controls.TextBlock; $t1.Text=$rotulo; $t1.FontSize=13; $t1.Foreground=(Br '#8FA6C3')
    $t2=New-Object Windows.Controls.TextBlock; $t2.Text='--'; $t2.FontSize=30; $t2.FontWeight='Bold'; $t2.Foreground=(Br $cor)
    [void]$sp.Children.Add($t1); [void]$sp.Children.Add($t2); $b.Child=$sp
    [void]$ch.Tiles.Children.Add($b); $ch.TileTxt[$id]=$t2
}
function Set-Tile($ch,[string]$id,[string]$txt){ $ch.TileTxt[$id].Text=$txt }
function Push-Chart($ch,[double[]]$vals){
    $w=$ch.Canvas.ActualWidth; $h=$ch.Canvas.ActualHeight; if($w -lt 10 -or $h -lt 10){ return }
    # grade
    if(-not $ch.PSObject.Properties['GradeOk']){
        foreach($f in 0.25,0.5,0.75){ $ln=New-Object Windows.Shapes.Line; $ln.X1=0; $ln.X2=4000; $ln.Y1=$h*$f; $ln.Y2=$h*$f; $ln.Stroke=(Br '#16304F'); $ln.StrokeThickness=1; $ln.StrokeDashArray=(New-Object Windows.Media.DoubleCollection (,[double[]]@(4,4))); $ch.Canvas.Children.Insert(0,$ln) }
        $ch | Add-Member -NotePropertyName GradeOk -NotePropertyValue $true
    }
    for($k=0;$k -lt $ch.Series.Count;$k++){
        $s=$ch.Series[$k]; $v=$vals[$k]
        if([double]::IsNaN($v)){ continue }
        [void]$s.Vals.Add([math]::Min($ch.Ymax,[math]::Max(0,$v))); while($s.Vals.Count -gt $ch.Pontos){ $s.Vals.RemoveAt(0) }
        $pc=New-Object Windows.Media.PointCollection; $dx=$w/($ch.Pontos-1)
        for($j=0;$j -lt $s.Vals.Count;$j++){ $pc.Add((New-Object Windows.Point(($j*$dx),($h-4-($s.Vals[$j]/$ch.Ymax)*($h-8))))) }
        $s.Line.Points=$pc
    }
}

$script:PnpCache=$null
function Get-Pnp { if(-not $script:PnpCache){ $script:PnpCache=@(Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue) }; return $script:PnpCache }

# ---------- teclas de atalho globais ----------
$script:KeyHook=$null
$Win.Add_PreviewKeyDown({ param($s,$e) if($script:KeyHook){ & $script:KeyHook $e } })
$ui_BtnSair.Add_Click({ Cleanup; $Win.Close() })
$Win.Add_Closed({ Cleanup; [Environment]::Exit(0) })

function Cleanup {
    try{ powercfg /setacvalueindex SCHEME_CURRENT SUB_BUTTONS LIDACTION 1 | Out-Null; powercfg /setdcvalueindex SCHEME_CURRENT SUB_BUTTONS LIDACTION 1 | Out-Null; powercfg /setactive SCHEME_CURRENT | Out-Null }catch{}
    try{ [void][MobNative]::SetThreadExecutionState([uint32]2147483648) }catch{}
}

# =====================================================================
#  FASE 1  -  TESTES AUTOMATICOS
# =====================================================================
$script:Info=[ordered]@{}
$script:Caps=@{}
$script:HasBat=$false
$Cfg=@{ Cpu=90; RamPct=70; RamLoops=2; DiscoGB=1.0; Comb=60; Nome='COMPLETO' }

function T-Info {
    Set-Screen 'Identificação do equipamento' 'Lendo fabricante, modelo e número de série...'
    $cs=Get-CimInstance Win32_ComputerSystem -Property Manufacturer,Model,TotalPhysicalMemory
    $bios=Get-CimInstance Win32_BIOS -Property SerialNumber,SMBIOSBIOSVersion
    $cpu=Get-CimInstance Win32_Processor -Property Name,NumberOfCores,NumberOfLogicalProcessors,MaxClockSpeed | Select-Object -First 1
    $serial=([string]$bios.SerialNumber).Trim(); if(-not $serial -or $serial -match '^(To be filled|Default|System Serial|0+)$'){ $serial='SEM-SERIAL' }
    $script:Info['Fabricante']=([string]$cs.Manufacturer).Trim()
    $script:Info['Modelo']=([string]$cs.Model).Trim()
    $script:Info['Número de série']=$serial
    $script:Info['Processador']=("{0} ({1} núcleos / {2} threads)" -f ([string]$cpu.Name).Trim(),$cpu.NumberOfCores,$cpu.NumberOfLogicalProcessors)
    $script:Info['Memória RAM']=("{0} GB" -f [math]::Round($cs.TotalPhysicalMemory/1GB,0))
    $script:Info['BIOS']=[string]$bios.SMBIOSBIOSVersion
    $script:CpuMHz=[int]$cpu.MaxClockSpeed
    $ui_Sub.Text=("{0} {1}   |   S/N {2}" -f $script:Info['Fabricante'],$script:Info['Modelo'],$serial)
    $script:Serial=$serial
    Live (($script:Info.GetEnumerator() | ForEach-Object { "{0,-17}: {1}" -f $_.Key,$_.Value }) -join "`r`n") 22
    Set-T 'info' 'OK' ("{0} {1} | S/N {2}" -f $script:Info['Fabricante'],$script:Info['Modelo'],$serial)
}

function T-Cpu {
    $n=[Environment]::ProcessorCount; $secs=[int]$Cfg.Cpu
    Set-Screen 'Processador (CPU) - estresse' ("Todos os $n threads a 100% por $secs s. Cada thread repete o mesmo cálculo e compara o resultado: qualquer diferença indica processador ou memória instável.")
    $ch=New-LiveChart @('Carga da CPU (%)','Velocidade (% do clock base)','Temperatura (°C)') @('#1E8BFF','#2EE59D','#FF8A3D') 120
    Add-Tile $ch 'carga' 'CARGA' '#35B6FF'; Add-Tile $ch 'clock' 'CLOCK' '#2EE59D'; Add-Tile $ch 'temp' 'TEMPERATURA' '#FF8A3D'; Add-Tile $ch 'erros' 'ERROS DE CÁLCULO' '#FFFFFF'
    $ui_Painel.Content=$ch.Grid; UI-Pump
    [void](Read-Perf)
    $s=New-Object CpuStress; $s.Start($n)
    $sw=[Diagnostics.Stopwatch]::StartNew(); $tmax=$null; $tnext=1; $perfs=New-Object System.Collections.ArrayList; $cargas=New-Object System.Collections.ArrayList
    while($sw.Elapsed.TotalSeconds -lt $secs){
        UI-Pump; Start-Sleep -Milliseconds 50
        $ui_Barra.Value=[math]::Min(100,$sw.Elapsed.TotalSeconds*100/$secs)
        if($sw.Elapsed.TotalSeconds -ge $tnext){
            $tnext+=1
            $r=Read-Perf
            if($null -ne $r.Temp -and ($null -eq $tmax -or $r.Temp -gt $tmax)){ $tmax=$r.Temp }
            if(-not [double]::IsNaN($r.Desemp) -and $sw.Elapsed.TotalSeconds -gt $secs/2){ [void]$perfs.Add($r.Desemp) }
            if(-not [double]::IsNaN($r.Carga)){ [void]$cargas.Add($r.Carga) }
            Push-Chart $ch @($r.Carga,$r.Desemp,$(if($null -ne $r.Temp){[double]$r.Temp}else{[double]::NaN}))
            Set-Tile $ch 'carga' $(if([double]::IsNaN($r.Carga)){'--'}else{"{0:N0}%" -f $r.Carga})
            Set-Tile $ch 'clock' $(if([double]::IsNaN($r.Desemp) -or -not $script:CpuMHz){'--'}else{"{0:N1} GHz" -f ($script:CpuMHz*$r.Desemp/100/1000)})
            Set-Tile $ch 'temp'  $(if($null -ne $r.Temp){"$($r.Temp) °C"}else{'sem sensor'})
            Set-Tile $ch 'erros' ("{0}" -f $s.Errors)
        }
    }
    $s.Stop=$true; $s.Join()
    $pmed= if($perfs.Count){[math]::Round(($perfs | Measure-Object -Average).Average,0)}else{$null}
    $cmed= if($cargas.Count){[math]::Round(($cargas | Measure-Object -Average).Average,0)}else{$null}
    $tTxt= if($null -ne $tmax){"$tmax °C"}else{'sensor não exposto pelo Windows'}
    $d=("{0} threads, {1} ciclos verificados, {2} erros | carga média {3}% | velocidade sob carga {4}% do clock base | temp. máx {5}" -f $n,$s.Ops,$s.Errors,$cmed,$pmed,$tTxt)
    $script:Info['Temperatura máx. CPU']=$tTxt
    if($s.Errors -gt 0){ Set-T 'cpu' 'FALHA' "Erros de cálculo detectados (CPU instável): $d" }
    elseif($null -ne $tmax -and $tmax -ge 97){ Set-T 'cpu' 'FALHA' "Superaquecimento: $d" }
    elseif($null -ne $tmax -and $tmax -ge 90){ Set-T 'cpu' 'ALERTA' "Temperatura alta: $d" }
    elseif($null -ne $pmed -and $pmed -lt 55){ Set-T 'cpu' 'ALERTA' "CPU reduzindo muito a velocidade sob carga (aquecimento, cooler sujo ou carregador fraco): $d" }
    else { Set-T 'cpu' 'OK' $d }
}

function T-Ram {
    $os=Get-CimInstance Win32_OperatingSystem -Property FreePhysicalMemory
    $freeB=[long]$os.FreePhysicalMemory*1024
    $target=[long][math]::Max(256MB,[math]::Min($freeB*$Cfg.RamPct/100,$freeB-768MB))
    Set-Screen 'Memória RAM' ("Gravando e conferindo padrões (AA/55/00/FF, endereçamento e pseudoaleatório) em {0:N1} GB usando todos os núcleos, {1} passada(s)." -f ($target/1GB),$Cfg.RamLoops)
    $r=New-Object RamTest; $r.RunAsync($target,[int]$Cfg.RamLoops)
    while(-not $r.Done){ UI-Pump; Start-Sleep -Milliseconds 150; $ui_Barra.Value=$r.Pct; Live ("Progresso: {0}%`r`nMemória sob teste: {1:N1} GB`r`nErros de dados: {2}" -f $r.Pct,($r.Tested/1GB),$r.Errors) 24 }
    $total=[math]::Round((Get-CimInstance Win32_ComputerSystem -Property TotalPhysicalMemory).TotalPhysicalMemory/1GB,1)
    $d=("{0:N1} GB testados de {1} GB instalados, {2} passada(s), {3} erros de dados" -f ($r.Tested/1GB),$total,$Cfg.RamLoops,$r.Errors)
    if($r.Errors -gt 0){ Set-T 'ram' 'FALHA' "Memória RAM com erro de dados: $d" }
    elseif($r.Err -and $r.Tested -lt 512MB){ Set-T 'ram' 'ALERTA' ("Teste não conseguiu reservar memória suficiente ({0}). $d" -f $r.Err) }
    else { if($r.Err){ Log ("RAM aviso: "+$r.Err) }; Set-T 'ram' 'OK' $d }
}

function T-Disco {
    Set-Screen 'Disco: saúde (SMART) e velocidade' 'Lendo contadores de confiabilidade e executando escrita/leitura sequencial com verificação de dados.'
    $notas=@(); $st='OK'
    $pd=@(Get-PhysicalDisk -ErrorAction SilentlyContinue)
    foreach($d in $pd){
        $rc=$null; try{ $rc=$d | Get-StorageReliabilityCounter -ErrorAction Stop }catch{}
        $linha=("{0} [{1}] saúde={2}" -f $d.FriendlyName,$d.MediaType,$d.HealthStatus)
        if($rc){
            if($null -ne $rc.Wear){ $linha+=" desgaste=$($rc.Wear)%" ; if($rc.Wear -ge 90){ $st='FALHA' } elseif($rc.Wear -ge 70 -and $st -ne 'FALHA'){ $st='ALERTA' } }
            if($null -ne $rc.Temperature){ $linha+=" temp=$($rc.Temperature)C"; if($rc.Temperature -ge 75 -and $st -eq 'OK'){ $st='ALERTA' } }
            if($null -ne $rc.PowerOnHours){ $linha+=" horas=$($rc.PowerOnHours)" }
            $er=[int64]($rc.ReadErrorsTotal)+[int64]($rc.WriteErrorsTotal)
            if($er -gt 0){ $linha+=" erros=$er"; if($st -eq 'OK'){ $st='ALERTA' } }
        }
        if($d.HealthStatus -ne 'Healthy'){ $st='FALHA' }
        $notas+=$linha; Log $linha
    }
    $path="$Base\disk_test.bin"; $bytes=[long]($Cfg.DiscoGB*1GB)
    $free=(Get-PSDrive C).Free; if($bytes -gt ($free-1GB)){ $bytes=[long][math]::Max(256MB,$free/4) }
    $dt=New-Object DiskTest; $dt.RunAsync($path,$bytes,$false)
    while(-not $dt.Done){ UI-Pump; Start-Sleep -Milliseconds 200; $ui_Barra.Value=$dt.Pct; Live ("Progresso: {0}%`r`nEscrita: {1:N0} MB/s   Leitura: {2:N0} MB/s`r`nErros de verificação: {3}" -f $dt.Pct,$dt.WriteMBs,$dt.ReadMBs,$dt.Errors) }
    $tipo=if($pd | Where-Object { $_.MediaType -eq 'HDD' }){'HDD'}else{'SSD'}
    $min= if($tipo -eq 'HDD'){40}else{150}
    $d=("Escrita {0:N0} MB/s | Leitura {1:N0} MB/s | {2} erros | {3}" -f $dt.WriteMBs,$dt.ReadMBs,$dt.Errors,($notas -join ' ; '))
    if($dt.Err){ Set-T 'disco' 'FALHA' ("Erro de E/S: "+$dt.Err) }
    elseif($dt.Errors -gt 0){ Set-T 'disco' 'FALHA' "Dados corrompidos na leitura. $d" }
    elseif($st -eq 'FALHA'){ Set-T 'disco' 'FALHA' $d }
    elseif($dt.WriteMBs -lt $min -and $st -eq 'OK'){ Set-T 'disco' 'ALERTA' "Disco lento (< $min MB/s). $d" }
    else { Set-T 'disco' $st $d }
}

function T-Bateria {
    Set-Screen 'Bateria: saúde' 'Gerando relatório de bateria do Windows (capacidade de projeto x capacidade atual, ciclos).'
    $b=Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue
    if(-not $b){ Set-T 'bat' 'PULADO' 'Nenhuma bateria detectada'; return }
    $script:HasBat=$true
    $design=$null; $full=$null; $cyc=$null
    try{
        $f="$RelDir\battery.xml"; Remove-Item $f -ErrorAction SilentlyContinue
        powercfg /batteryreport /xml /output $f | Out-Null
        [xml]$x=Get-Content $f -Raw
        $bt=@($x.BatteryReport.Batteries.Battery)[0]
        $design=[double]$bt.DesignCapacity; $full=[double]$bt.FullChargeCapacity; $cyc=$bt.CycleCount
    }catch{}
    if(-not $design){
        try{ $design=[double](Get-CimInstance -Namespace root/wmi BatteryStaticData | Select-Object -First 1).DesignedCapacity; $full=[double](Get-CimInstance -Namespace root/wmi BatteryFullChargedCapacity | Select-Object -First 1).FullChargedCapacity }catch{}
    }
    $nivel=$b.EstimatedChargeRemaining
    if(-not $design){ Set-T 'bat' 'ALERTA' "Bateria presente ($nivel%), mas o Windows não informou a capacidade"; return }
    $saude=[math]::Round($full*100/$design,0)
    $d=("Saúde {0}% ({1} de {2} mWh), ciclos: {3}, carga atual {4}%" -f $saude,$full,$design,$(if($cyc){$cyc}else{'n/d'}),$nivel)
    $script:Info['Bateria']=$d
    Live $d 24
    if($saude -ge 80){ Set-T 'bat' 'OK' $d } elseif($saude -ge 60){ Set-T 'bat' 'ALERTA' "Bateria desgastada: $d" } else { Set-T 'bat' 'FALHA' "Bateria no fim da vida: $d" }
}

# Windows 11 24H2+: sem a Localizacao ligada o "netsh wlan" nao mostra SSID/sinal nem lista redes
function Enable-Location {
    $cs='SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\location'
    foreach($k in "HKLM:\$cs","HKCU:\$cs","HKCU:\$cs\NonPackaged"){
        try{ if(-not (Test-Path $k)){ New-Item -Path $k -Force | Out-Null }; Set-ItemProperty -Path $k -Name Value -Value 'Allow' -Type String -Force }catch{}
    }
    try{ Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\lfsvc\Service\Configuration' -Name Status -Value 1 -Type DWord -Force }catch{}
    try{ Start-Service lfsvc -ErrorAction SilentlyContinue }catch{}
}
function Get-WifiInfo($a){
    $r=[ordered]@{ Ssid=''; Sinal=$null; Link=''; Padrao=''; Fonte='netsh' }
    $ni=(netsh wlan show interfaces) -join "`n"
    if($ni -match '(?m)^\s*(Sinal|Signal)\s*:\s*(\d+)%'){ $r.Sinal=[int]$Matches[2] }
    if($ni -match '(?m)^\s*SSID\s*:\s*(.+)$'){ $r.Ssid=$Matches[1].Trim() }
    if($ni -match '(?m)^\s*(Taxa de recep[^:]*|Receive rate[^:]*)\s*:\s*([\d\.,]+)'){ $r.Link=$Matches[2] }
    if($ni -match '(?m)^\s*(Tipo de r[^:]*|Radio type)\s*:\s*(.+)$'){ $r.Padrao=$Matches[2].Trim() }
    if(-not $r.Ssid){
        $st=(Get-NetAdapter -InterfaceIndex $a.ifIndex -ErrorAction SilentlyContinue).Status
        if($st -eq 'Up'){
            try{ $r.Ssid=[string](Get-NetConnectionProfile -InterfaceIndex $a.ifIndex -ErrorAction Stop | Select-Object -First 1).Name; $r.Fonte='perfil de rede (netsh bloqueado pela permissao de localizacao)' }catch{}
        }
    }
    return [pscustomobject]$r
}

function T-Rede {
    Set-Screen 'Wi-Fi e rede' 'Verificando adaptador, sinal, perda de pacotes e velocidade real de download.'
    [Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12
    Enable-Location
    $wifi=@(Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object { $_.PhysicalMediaType -match '802\.11' -or $_.InterfaceDescription -match 'Wireless|Wi-?Fi|WLAN|802\.11' })
    $eth=@(Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object { $_.PhysicalMediaType -match '802\.3' -and $_.InterfaceDescription -notmatch 'Bluetooth|Wireless|Wi-?Fi' })
    if(-not $wifi.Count){ Set-T 'rede' 'FALHA' 'Nenhum adaptador Wi-Fi encontrado (placa ausente ou sem driver)'; return }
    $a=@($wifi | Sort-Object @{Expression={ if($_.Status -eq 'Up'){0}else{1} }})[0]
    if($a.Status -eq 'Disabled'){ try{ Enable-NetAdapter -Name $a.Name -Confirm:$false -ErrorAction Stop; Wait-UI 4000 }catch{} }
    $notas=@("Adaptador: $($a.InterfaceDescription)")
    $ethUp=@($eth | Where-Object { $_.Status -eq 'Up' })
    if($eth.Count){ $notas+="Ethernet: $($eth[0].InterfaceDescription) [$($eth[0].Status), $($eth[0].LinkSpeed)]" }
    $wi=Get-WifiInfo $a
    if(-not $wi.Ssid){
        # tenta reconectar nas redes da MOB que o assistente deixou salvas no Windows
        $cfg=Get-ItemProperty -Path 'HKLM:\SOFTWARE\MOB' -ErrorAction SilentlyContinue
        $lista=@(@($cfg.WifiSSID,$cfg.WifiSSID2,$cfg.WifiSSID3) | Where-Object { $_ })
        foreach($s in $lista){
            Live ("Wi-Fi desconectado. Tentando conectar na rede salva '{0}'..." -f $s) 20
            $o=netsh wlan connect name="$s" interface="$($a.Name)"; Log ("netsh connect {0}: {1}" -f $s,($o -join ' '))
            $sw=[Diagnostics.Stopwatch]::StartNew()
            while($sw.Elapsed.TotalSeconds -lt 15){ Wait-UI 1000; if((Get-NetAdapter -InterfaceIndex $a.ifIndex -ErrorAction SilentlyContinue).Status -eq 'Up'){ break } }
            Wait-UI 3000
            $wi=Get-WifiInfo $a
            if($wi.Ssid){ break }
        }
    }
    if($wi.Padrao){ $notas+="Padrao: $($wi.Padrao)" }
    if($wi.Link){ $notas+="Link: $($wi.Link) Mbps" }
    if(-not $wi.Ssid){ Set-T 'rede' 'ALERTA' (($notas -join ' | ') + ' | Wi-Fi não está conectado (a placa existe, mas não conectou em nenhuma rede)'); return }
    $notas+=("Rede: {0}, sinal {1}" -f $wi.Ssid,$(if($null -ne $wi.Sinal){"$($wi.Sinal)%"}else{'n/d'}))
    if($wi.Fonte -ne 'netsh'){ $notas+="SSID lido pelo $($wi.Fonte)" }
    if($ethUp.Count){ $notas+='ATENÇÃO: cabo de rede conectado - a velocidade pode ter sido medida pelo cabo' }
    # ping com .NET (Test-Connection -AsJob conta pings perdidos como recebidos)
    $pg=New-Object Net.NetworkInformation.Ping; $alvo=''; $okP=0; $tms=@()
    foreach($dst in '1.1.1.1','8.8.8.8'){
        $okP=0; $tms=@(); $alvo=$dst
        for($i=0;$i -lt 10;$i++){
            try{ $rp=$pg.Send($dst,1000); if($rp.Status -eq 'Success'){ $okP++; $tms+=[int]$rp.RoundtripTime } }catch{}
            UI-Pump; Start-Sleep -Milliseconds 150
        }
        if($okP -gt 0){ break }
    }
    $perda=100-($okP*10); $lat=if($tms.Count){[math]::Round(($tms | Measure-Object -Average).Average)}else{0}
    $speeds=@()
    for($i=1;$i -le 3;$i++){
        try{
            $ui_Barra.Value=$i*33
            $wc=New-Object Net.WebClient; $sw=[Diagnostics.Stopwatch]::StartNew()
            $tk=$wc.DownloadDataTaskAsync('https://speed.cloudflare.com/__down?bytes=25000000')
            while(-not $tk.IsCompleted){ UI-Pump; Start-Sleep -Milliseconds 50 }
            if($tk.Status -eq 'RanToCompletion'){ $mb=($tk.Result.Length*8)/1e6; $speeds+=[math]::Round($mb/$sw.Elapsed.TotalSeconds,1) }
        }catch{}
        Live ("Rede: {0}`r`nPing {1}: perda {2}%, {3} ms`r`nVelocidades medidas (Mbps): {4}" -f $wi.Ssid,$alvo,$perda,$lat,($speeds -join ', '))
    }
    $avg= if($speeds.Count){[math]::Round(($speeds | Measure-Object -Average).Average,1)}else{0}
    $icmpBloq=($okP -eq 0 -and $avg -gt 0)
    if($icmpBloq){ $notas+='Ping: sem resposta (ICMP provavelmente bloqueado pela rede)' } else { $notas+="Ping ${alvo}: perda $perda%, $lat ms" }
    $notas+="Download medio: $avg Mbps"
    $d=$notas -join ' | '
    if($avg -eq 0 -or ($perda -ge 30 -and -not $icmpBloq)){ Set-T 'rede' 'FALHA' $d }
    elseif(($null -ne $wi.Sinal -and $wi.Sinal -lt 40) -or ($perda -ge 10 -and -not $icmpBloq) -or $avg -lt 10){ Set-T 'rede' 'ALERTA' $d }
    else { Set-T 'rede' 'OK' $d }
}

function T-Bluetooth {
    Set-Screen 'Bluetooth' 'Procurando o radio Bluetooth e verificando o servico.'
    $bt=@(Get-Pnp | Where-Object { $_.Class -eq 'Bluetooth' -and $_.InstanceId -match '^(USB|PCI|ACPI|SERIAL|ROOT)\\' })
    if(-not $bt.Count){ Set-T 'bt' 'FALHA' 'Radio Bluetooth não encontrado (placa ausente, desativada na BIOS ou sem driver)'; return }
    $svc=Get-Service bthserv -ErrorAction SilentlyContinue
    $d=("{0} [{1}] | servico: {2}" -f $bt[0].FriendlyName,$bt[0].Status,$(if($svc){$svc.Status}else{'n/d'}))
    $script:Caps.BT=$true
    if($bt[0].Status -ne 'OK'){ Set-T 'bt' 'FALHA' $d } else { Set-T 'bt' 'OK' $d }
}

function T-Gpu {
    Set-Screen 'Video / GPU' 'Verificando adaptador e driver, depois 12 s de animacao pesada (60+ camadas com sombra/rotacao) medindo FPS.'
    $vc=@(Get-CimInstance Win32_VideoController)
    $nomes=($vc | ForEach-Object { "{0} (driver {1})" -f $_.Name,$_.DriverVersion }) -join ' | '
    $basico=@($vc | Where-Object { $_.Name -match 'Basic Display|Basico' }).Count -gt 0
    $erro=@($vc | Where-Object { $_.ConfigManagerErrorCode -ne 0 }).Count
    $tier=[Windows.Media.RenderCapability]::Tier -shr 16
    $cv=New-Object Windows.Controls.Canvas; $cv.Background=(Br '#000000'); $cv.ClipToBounds=$true
    $rnd=New-Object Random
    for($i=0;$i -lt 70;$i++){
        $r=New-Object Windows.Shapes.Rectangle; $r.Width=120+$rnd.Next(120); $r.Height=60+$rnd.Next(120)
        $col='#{0:X2}{1:X2}{2:X2}' -f (80+$rnd.Next(170)),(80+$rnd.Next(170)),(80+$rnd.Next(170))
        $r.Fill=(Br $col); $r.Opacity=0.7; $r.RenderTransformOrigin=New-Object Windows.Point(0.5,0.5)
        $r.Effect=New-Object Windows.Media.Effects.DropShadowEffect -Property @{BlurRadius=24;ShadowDepth=8}
        $rt=New-Object Windows.Media.RotateTransform; $r.RenderTransform=$rt
        $an=New-Object Windows.Media.Animation.DoubleAnimation(0,360,[TimeSpan]::FromSeconds(1.5+$rnd.NextDouble()*2))
        $an.RepeatBehavior=[Windows.Media.Animation.RepeatBehavior]::Forever
        $rt.BeginAnimation([Windows.Media.RotateTransform]::AngleProperty,$an)
        [Windows.Controls.Canvas]::SetLeft($r,$rnd.Next(900)); [Windows.Controls.Canvas]::SetTop($r,$rnd.Next(380))
        [void]$cv.Children.Add($r)
    }
    $ui_Painel.Content=$cv
    $script:Frames=0
    $h=[EventHandler]{ param($s,$e) $script:Frames++ }
    [Windows.Media.CompositionTarget]::add_Rendering($h)
    $sw=[Diagnostics.Stopwatch]::StartNew()
    while($sw.Elapsed.TotalSeconds -lt 12){ UI-Pump; Start-Sleep -Milliseconds 20; $ui_Barra.Value=$sw.Elapsed.TotalSeconds*100/12 }
    [Windows.Media.CompositionTarget]::remove_Rendering($h)
    $fps=[math]::Round($script:Frames/$sw.Elapsed.TotalSeconds,1)
    $ui_Painel.Content=$null
    $d=("{0} | FPS medio {1} | camada de renderização (tier) {2}" -f $nomes,$fps,$tier)
    if($erro){ Set-T 'gpu' 'FALHA' "Adaptador de video com erro no Windows. $d" }
    elseif($basico){ Set-T 'gpu' 'ALERTA' "Usando 'Microsoft Basic Display' - driver de video NÃO instalado. $d" }
    elseif($tier -eq 0 -or $fps -lt 20){ Set-T 'gpu' 'ALERTA' "Renderização fraca/por software. $d" }
    else { Set-T 'gpu' 'OK' $d }
}

function T-Drivers {
    Set-Screen 'Drivers e dispositivos' 'Procurando dispositivos com erro ou sem driver no Gerenciador de Dispositivos.'
    $bad=@(Get-CimInstance Win32_PnPEntity | Where-Object { $_.ConfigManagerErrorCode -ne 0 })
    if($bad.Count){
        $lista=($bad | ForEach-Object { "{0} (cod {1})" -f $(if($_.Name){$_.Name}else{$_.PNPDeviceID}),$_.ConfigManagerErrorCode }) -join '; '
        Live ($bad | ForEach-Object { "- {0}  [erro {1}]" -f $(if($_.Name){$_.Name}else{$_.PNPDeviceID}),$_.ConfigManagerErrorCode } | Out-String) 15
        Set-T 'drv' 'ALERTA' ("{0} dispositivo(s) com problema: {1}" -f $bad.Count,$lista)
    } else { Set-T 'drv' 'OK' 'Nenhum dispositivo com erro no Gerenciador de Dispositivos' }
}

function T-Sensores {
    Set-Screen 'Detecção de recursos' 'Descobrindo o que este notebook possui: touch, biometria, webcam, microfone, sensor de luz, touchpad.'
    $p=Get-Pnp
    $f=@{}
    $f.Touch = @($p | Where-Object { $_.FriendlyName -match 'touch screen|tela sens|HID-compliant touch' }).Count -gt 0
    $f.Bio   = @($p | Where-Object { $_.Class -eq 'Biometric' -or $_.FriendlyName -match 'fingerprint|digital|biom' })
    $f.Cam   = @($p | Where-Object { $_.Class -in 'Camera','Image' -and $_.FriendlyName -notmatch 'scanner' })
    $f.Mic   = @($p | Where-Object { $_.Class -eq 'AudioEndpoint' -and $_.FriendlyName -match 'Micro|Microphone|Mic' })
    $f.Spk   = @($p | Where-Object { $_.Class -eq 'AudioEndpoint' -and $_.FriendlyName -match 'Speaker|Alto-falante|Auto' })
    $f.Luz   = @($p | Where-Object { $_.Class -eq 'Sensor' -and $_.FriendlyName -match 'Light|Luz|Ambient' })
    $f.Pad   = @($p | Where-Object { $_.Class -eq 'Mouse' -and $_.FriendlyName -match 'Touch ?pad|Synaptics|ELAN|Precision|I2C' })
    $script:Caps.Touch=$f.Touch; $script:Caps.Bio=$f.Bio.Count -gt 0; $script:Caps.Cam=$f.Cam.Count -gt 0; $script:Caps.Mic=$f.Mic.Count -gt 0
    $script:Caps.Spk=$f.Spk.Count -gt 0; $script:Caps.Luz=$f.Luz.Count -gt 0; $script:Caps.Pad=$f.Pad.Count -gt 0
    $linhas=@(
        ("Tela touch      : {0}" -f $(if($f.Touch){'detectada'}else{'não'})),
        ("Leitor biometrico: {0}" -f $(if($f.Bio.Count){ ($f.Bio | ForEach-Object { "$($_.FriendlyName) [$($_.Status)]" }) -join ', ' }else{'não'})),
        ("Webcam          : {0}" -f $(if($f.Cam.Count){ ($f.Cam | ForEach-Object { "$($_.FriendlyName) [$($_.Status)]" }) -join ', ' }else{'NÃO DETECTADA'})),
        ("Microfone       : {0}" -f $(if($f.Mic.Count){ ($f.Mic | ForEach-Object { $_.FriendlyName }) -join ', ' }else{'NÃO DETECTADO'})),
        ("Alto-falantes   : {0}" -f $(if($f.Spk.Count){ ($f.Spk | ForEach-Object { $_.FriendlyName }) -join ', ' }else{'NÃO DETECTADOS'})),
        ("Sensor de luz   : {0}" -f $(if($f.Luz.Count){'detectado'}else{'não'})),
        ("Touchpad        : {0}" -f $(if($f.Pad.Count){ ($f.Pad | ForEach-Object { $_.FriendlyName }) -join ', ' }else{'não identificado pelo nome'}))
    )
    Live ($linhas -join "`r`n") 17
    $script:Info['Recursos']=($linhas -join ' | ')
    $falta=@(); if(-not $f.Cam.Count){$falta+='webcam'}; if(-not $f.Mic.Count){$falta+='microfone'}; if(-not $f.Spk.Count){$falta+='alto-falantes'}
    $bioBad=@($f.Bio | Where-Object { $_.Status -ne 'OK' })
    if($bioBad.Count){ Set-T 'sens' 'ALERTA' ("Leitor biometrico com status "+$bioBad[0].Status) }
    elseif($falta.Count){ Set-T 'sens' 'ALERTA' ("Não detectado: "+($falta -join ', ')) }
    else { Set-T 'sens' 'OK' 'Webcam, microfone e alto-falantes detectados' }
}

function T-Combinado {
    $secs=[int]$Cfg.Comb; $n=[Environment]::ProcessorCount
    Set-Screen 'Estresse combinado (CPU + RAM + disco)' ("Por $secs s: todos os núcleos, parte da RAM livre e escrita contínua em disco ao mesmo tempo. Simula o pior caso de energia e temperatura.")
    $ch=New-LiveChart @('Carga da CPU (%)','Velocidade (% do clock base)','Temperatura (°C)') @('#1E8BFF','#2EE59D','#FF8A3D') 120
    Add-Tile $ch 'temp' 'TEMPERATURA' '#FF8A3D'; Add-Tile $ch 'erros' 'ERROS CPU / RAM / DISCO' '#FFFFFF'; Add-Tile $ch 'disco' 'DISCO (ESCRITA)' '#35B6FF'
    $ui_Painel.Content=$ch.Grid; UI-Pump
    $os=Get-CimInstance Win32_OperatingSystem -Property FreePhysicalMemory; $freeB=[long]$os.FreePhysicalMemory*1024
    $target=[long][math]::Max(256MB,[math]::Min($freeB*0.4,$freeB-1GB))
    [void](Read-Perf)
    $cpu=New-Object CpuStress; $ram=New-Object RamTest; $dsk=New-Object DiskTest
    $cpu.Start($n); $ram.RunAsync($target,1000); $dsk.RunAsync("$Base\stress.bin",512MB,$true)
    $sw=[Diagnostics.Stopwatch]::StartNew(); $tmax=$null; $tnext=1
    while($sw.Elapsed.TotalSeconds -lt $secs){
        UI-Pump; Start-Sleep -Milliseconds 50
        $ui_Barra.Value=[math]::Min(100,$sw.Elapsed.TotalSeconds*100/$secs)
        if($sw.Elapsed.TotalSeconds -ge $tnext){
            $tnext+=1; $r=Read-Perf
            if($null -ne $r.Temp -and ($null -eq $tmax -or $r.Temp -gt $tmax)){ $tmax=$r.Temp }
            Push-Chart $ch @($r.Carga,$r.Desemp,$(if($null -ne $r.Temp){[double]$r.Temp}else{[double]::NaN}))
            Set-Tile $ch 'temp' $(if($null -ne $r.Temp){"$($r.Temp) °C"}else{'sem sensor'})
            Set-Tile $ch 'erros' ("{0} / {1} / {2}" -f $cpu.Errors,$ram.Errors,$dsk.Errors)
            Set-Tile $ch 'disco' ("{0:N0} MB/s" -f $dsk.WriteMBs)
        }
    }
    $cpu.Stop=$true; $ram.Cancel=$true; $dsk.Cancel=$true; $cpu.Join()
    $w=[Diagnostics.Stopwatch]::StartNew(); while((-not $ram.Done -or -not $dsk.Done) -and $w.Elapsed.TotalSeconds -lt 60){ UI-Pump; Start-Sleep -Milliseconds 100 }
    Remove-Item "$Base\stress.bin" -ErrorAction SilentlyContinue
    $err=$cpu.Errors+$ram.Errors+$dsk.Errors
    $tTxt= if($null -ne $tmax){"$tmax °C"}else{'n/d'}
    $d=("{0}s | erros CPU/RAM/Disco: {1}/{2}/{3} | temp máx {4} | escrita {5:N0} MB/s" -f $secs,$cpu.Errors,$ram.Errors,$dsk.Errors,$tTxt,$dsk.WriteMBs)
    if($dsk.Err){ Log ("Disco (combinado): "+$dsk.Err) }
    if($err -gt 0){ Set-T 'comb' 'FALHA' "Instabilidade sob carga: $d" }
    elseif($dsk.Err){ Set-T 'comb' 'FALHA' "Erro de gravação no disco sob carga ($($dsk.Err)). $d" }
    elseif($null -ne $tmax -and $tmax -ge 97){ Set-T 'comb' 'FALHA' "Superaquecimento: $d" }
    elseif($null -ne $tmax -and $tmax -ge 90){ Set-T 'comb' 'ALERTA' "Temperatura alta: $d" }
    else { Set-T 'comb' 'OK' $d }
}

# =====================================================================
#  FASE 2  -  TESTES COM ACAO FISICA
# =====================================================================
function New-TargetGrid($items,[int]$cols){
    $g=New-Object Windows.Controls.Primitives.UniformGrid; $g.Columns=$cols
    foreach($it in $items){
        $b=New-Object Windows.Controls.Border
        $b.Background=(Br '#1B2430'); $b.BorderBrush=(Br '#3A4A5E'); $b.BorderThickness='2'; $b.Margin='6'; $b.CornerRadius='10'
        $b.Tag=$it.A; $b.Uid=''
        $tb=New-Object Windows.Controls.TextBlock; $tb.Text=$it.T; $tb.FontSize=18; $tb.TextAlignment='Center'; $tb.TextWrapping='Wrap'
        $tb.HorizontalAlignment='Center'; $tb.VerticalAlignment='Center'; $tb.IsHitTestVisible=$false
        $b.Child=$tb; [void]$g.Children.Add($b)
    }
    return $g
}
function Mark-Target($b){
    if($b.Uid -ne 'done'){ $b.Uid='done'; $b.Background=(Br '#1E6B3E'); $b.BorderBrush=(Br '#3DDC84'); $script:TgDone++ }
}
# executa um teste de "alvos": termina sozinho quando todos forem acionados
function Run-TargetTest($id,$grid,[int]$total,[string]$rotuloDefeito,[int]$timeoutSec=0){
    $script:TgDone=0
    $ui_Painel.Content=$grid
    Show-Buttons @($rotuloDefeito,'Pular')
    $sw=[Diagnostics.Stopwatch]::StartNew(); $tmo=$false
    while($script:TgDone -lt $total -and $null -eq $script:Clicked){
        UI-Pump; Start-Sleep -Milliseconds 40
        $ui_Barra.Value=$script:TgDone*100/$total
        if($timeoutSec -gt 0 -and $sw.Elapsed.TotalSeconds -gt $timeoutSec){ $tmo=$true; break }
    }
    $c=$script:Clicked; Clear-Buttons
    if($script:TgDone -ge $total){ Set-T $id 'OK' "$total/$total alvos acionados" }
    elseif($c -eq 'Pular'){ Set-T $id 'PULADO' 'Pulado pelo técnico' }
    elseif($tmo){ Set-T $id 'FALHA' ("Tempo esgotado: apenas {0} de {1} alvos responderam" -f $script:TgDone,$total) }
    else { Set-T $id 'FALHA' ("Apenas {0} de {1} alvos responderam" -f $script:TgDone,$total) }
}

function Show-Color([string]$spec,[int]$ms=1400){
    $w=New-Object Windows.Window; $w.WindowStyle='None'; $w.WindowState='Maximized'; $w.Topmost=$true; $w.Cursor=[Windows.Input.Cursors]::None
    if($spec -eq 'GRAD'){
        $g=New-Object Windows.Media.LinearGradientBrush; $g.StartPoint='0,0'; $g.EndPoint='1,0'
        [void]$g.GradientStops.Add((New-Object Windows.Media.GradientStop([Windows.Media.Colors]::Black,0)))
        [void]$g.GradientStops.Add((New-Object Windows.Media.GradientStop([Windows.Media.Colors]::White,1)))
        $w.Background=$g
    } else { $w.Background=(Br $spec) }
    $w.Show(); $sw=[Diagnostics.Stopwatch]::StartNew()
    while($sw.ElapsedMilliseconds -lt $ms){ try{ $w.Dispatcher.Invoke([Action]{}, [Windows.Threading.DispatcherPriority]::Background) }catch{}; Start-Sleep -Milliseconds 30 }
    $w.Close()
}

function T-Tela {
    Set-Screen 'Tela e brilho' 'Automático: o brilho é variado sozinho e as cores de tela cheia passam sozinhas (preto, branco, vermelho, verde, azul, cinza, degradê). Observe pixels mortos, manchas, vazamento de luz e linhas.'
    $res=@(); $brOK=$true; $brTxt=''
    try{
        $m=Get-CimInstance -Namespace root/wmi -ClassName WmiMonitorBrightnessMethods -ErrorAction Stop | Select-Object -First 1
        $orig=(Get-CimInstance -Namespace root/wmi -ClassName WmiMonitorBrightness | Select-Object -First 1).CurrentBrightness
        foreach($lv in 100,30,100,[int]$orig){
            [void](Invoke-CimMethod -InputObject $m -MethodName WmiSetBrightness -Arguments @{Timeout=1;Brightness=[byte]$lv})
            Wait-UI 900
            $cur=(Get-CimInstance -Namespace root/wmi -ClassName WmiMonitorBrightness | Select-Object -First 1).CurrentBrightness
            $res+="$lv->$cur"; if([math]::Abs($cur-$lv) -gt 12){ $brOK=$false }
        }
        Log ("Brilho (pedido->lido): "+($res -join ', '))
        $brTxt=if($brOK){'Brilho: OK (varia por software)'}else{'Brilho: não respondeu como esperado'}
    }catch{ $brTxt='Brilho: controle por software indisponível neste equipamento' }
    Live ($brTxt+"`r`n`r`nIniciando as cores de tela cheia...") 20; Wait-UI 800
    foreach($c in '#000000','#FFFFFF','#FF0000','#00FF00','#0000FF','#808080','GRAD'){ Show-Color $c 1400 }
    $Win.Activate() | Out-Null
    Live ($brTxt+"`r`n`r`nA imagem estava perfeita (sem pixel morto, mancha ou linha)?") 20
    $r=Wait-Click @('Tela perfeita','Pixel morto / mancha / linha','Pular')
    if($r -eq 'Tela perfeita'){ if($brOK -or $brTxt -match 'indispon'){ Set-T 'tela' 'OK' $brTxt } else { Set-T 'tela' 'ALERTA' "Imagem OK, mas $brTxt" } }
    elseif($r -eq 'Pular'){ Set-T 'tela' 'PULADO' 'Pulado pelo técnico' }
    else { Set-T 'tela' 'FALHA' "Defeito visual reportado. $brTxt" }
}

function T-Teclado {
    Set-Screen 'Teclado' 'Pressione TODAS as teclas. Cada tecla fica verde ao ser detectada. Tecla que não existe neste modelo: clique nela para marcar N/A. A tecla Windows abre o Menu Iniciar - é normal, o teste volta sozinho.'
    $rows=@(
      @('Esc|Escape|1.3','F1|F1','F2|F2','F3|F3','F4|F4','F5|F5','F6|F6','F7|F7','F8|F8','F9|F9','F10|F10','F11|F11','F12|F12','PrtSc|Snapshot','Ins|Insert','Del|Delete'),
      @("'|OemTilde",'1|D1','2|D2','3|D3','4|D4','5|D5','6|D6','7|D7','8|D8','9|D9','0|D0','-|OemMinus','=|OemPlus','Backspace|Back|2'),
      @('Tab|Tab|1.5','Q|Q','W|W','E|E','R|R','T|T','Y|Y','U|U','I|I','O|O','P|P','´ `|OemOpenBrackets','[ {|OemCloseBrackets','Enter|Return|1.5'),
      @('Caps|Capital|1.8','A|A','S|S','D|D','F|F','G|G','H|H','J|J','K|K','L|L','Ç|OemSemicolon','~ ^|OemQuotes','] }|OemPipe'),
      @('Shift|LeftShift|1.4','\|OemBackslash','Z|Z','X|X','C|C','V|V','B|B','N|N','M|M',',|OemComma','.|OemPeriod','; :|OemQuestion','/ ?|AbntC1','Shift|RightShift|2'),
      @('Ctrl|LeftCtrl|1.3','Win|LWin|1.2','Alt|LeftAlt|1.2','Espaço|Space|5.5','AltGr|RightAlt|1.2','Ctrl|RightCtrl|1.3','<|Left','^|Up','v|Down','>|Right','Home|Home','End|End','PgUp|Prior','PgDn|Next')
    )
    $numpad=@('NumLk|NumLock','/|Divide','*|Multiply','-|Subtract','7|NumPad7','8|NumPad8','9|NumPad9','+|Add','4|NumPad4','5|NumPad5','6|NumPad6','1|NumPad1','2|NumPad2','3|NumPad3','0|NumPad0|2','.|Decimal')
    $script:KeyMap=@{}; $script:KeyState=@{}; $script:NumKeys=@()
    $root=New-Object Windows.Controls.StackPanel; $root.HorizontalAlignment='Center'; $root.VerticalAlignment='Center'
    $mk={
        param($spec,[bool]$isNum)
        $p=$spec -split '\|'; $w= if($p.Count -ge 3){[double]$p[2]}else{1.0}
        $b=New-Object Windows.Controls.Border; $b.Width=[math]::Round(54*$w); $b.Height=48; $b.Margin='2'; $b.CornerRadius='6'
        $b.Background=(Br '#1B2430'); $b.BorderBrush=(Br '#3A4A5E'); $b.BorderThickness='1'; $b.Tag=$p[1]
        $t=New-Object Windows.Controls.TextBlock; $t.Text=$p[0]; $t.FontSize=13; $t.HorizontalAlignment='Center'; $t.VerticalAlignment='Center'; $t.IsHitTestVisible=$false
        $b.Child=$t
        $script:KeyMap[$p[1]]=$b; $script:KeyState[$p[1]]=''
        if($isNum){ $script:NumKeys+=$p[1] }
        $b.Add_MouseLeftButtonDown({ param($s,$e)
            $n=[string]$s.Tag
            if($script:KeyState[$n] -eq ''){ $script:KeyState[$n]='na'; $s.Background=(Br '#4A3F1A') }
            elseif($script:KeyState[$n] -eq 'na'){ $script:KeyState[$n]=''; $s.Background=(Br '#1B2430') } })
        return $b
    }
    foreach($r in $rows){
        $sp=New-Object Windows.Controls.StackPanel; $sp.Orientation='Horizontal'; $sp.HorizontalAlignment='Left'
        foreach($k in $r){ [void]$sp.Children.Add((& $mk $k $false)) }
        [void]$root.Children.Add($sp)
    }
    $sp=New-Object Windows.Controls.WrapPanel; $sp.Width=240; $sp.Margin='0,10,0,0'; $sp.HorizontalAlignment='Left'
    foreach($k in $numpad){ [void]$sp.Children.Add((& $mk $k $true)) }
    [void]$root.Children.Add($sp)
    $ui_Painel.Content=$root
    $script:ExtraKeys=@()
    $script:KeyHook={ param($e)
        $k=$e.Key
        if($k -eq 'System'){ $k=$e.SystemKey }
        if($k -eq 'ImeProcessed'){ $k=$e.ImeProcessedKey }
        if($k -eq 'DeadCharProcessed'){ $k=$e.DeadCharProcessedKey }
        $e.Handled=$true; $n=$k.ToString()
        if($script:KeyMap.ContainsKey($n)){
            if($script:KeyState[$n] -ne 'ok'){ $script:KeyState[$n]='ok'; $script:KeyMap[$n].Background=(Br '#1E6B3E'); $script:KeyMap[$n].BorderBrush=(Br '#3DDC84') }
        } else { $script:ExtraKeys+=$n }
    }
    $Win.Focus() | Out-Null
    $labels=@('Sem teclado numérico','Teclado com defeito','Pular'); Show-Buttons $labels
    $falta=1
    while($falta -gt 0){
        UI-Pump; Start-Sleep -Milliseconds 40
        if(-not $Win.IsActive){ $Win.Activate() | Out-Null }
        $falta=@($script:KeyState.Keys | Where-Object { $script:KeyState[$_] -eq '' }).Count
        $ui_Barra.Value=100*(($script:KeyState.Count-$falta)/$script:KeyState.Count)
        if($script:Clicked -eq 'Sem teclado numérico'){
            foreach($n in $script:NumKeys){ if($script:KeyState[$n] -eq ''){ $script:KeyState[$n]='na'; $script:KeyMap[$n].Background=(Br '#4A3F1A') } }
            Show-Buttons @('Teclado com defeito','Pular')
        }
        elseif($script:Clicked){ break }
    }
    $c=$script:Clicked; Clear-Buttons; $script:KeyHook=$null
    $miss=@($script:KeyState.Keys | Where-Object { $script:KeyState[$_] -eq '' }) -join ', '
    $na=@($script:KeyState.Keys | Where-Object { $script:KeyState[$_] -eq 'na' }).Count
    if($falta -eq 0){ Set-T 'tec' 'OK' ("Todas as teclas responderam ({0} marcadas N/A)" -f $na) }
    elseif($c -eq 'Pular'){ Set-T 'tec' 'PULADO' 'Pulado pelo técnico' }
    else { Set-T 'tec' 'FALHA' ("Teclas sem resposta: "+$miss) }
}

function T-Touchpad {
    Set-Screen 'Touchpad - botões' 'Use SÓ o touchpad (sem mouse USB): clique com o botão ESQUERDO no quadro da esquerda e com o botão DIREITO no quadro da direita. O teste avança sozinho.'
    $it=@( @{T='Botão ESQUERDO';A='L'}, @{T='Botão DIREITO';A='R'} )
    $g=New-TargetGrid $it 2
    foreach($b in $g.Children){
        $b.Add_MouseLeftButtonDown({ param($s,$e) if($s.Tag -eq 'L'){ Mark-Target $s } })
        $b.Add_MouseRightButtonDown({ param($s,$e) if($s.Tag -eq 'R'){ Mark-Target $s } })
    }
    Run-TargetTest 'tp' $g 2 'Touchpad com defeito' 90
}

function T-Touch {
    if(-not $script:Caps.Touch){ Set-T 'touch' 'PULADO' 'Este equipamento não possui tela touch'; return }
    Set-Screen 'Tela touch' 'Toque com o dedo em TODOS os quadros, inclusive nos cantos e bordas. Se tiver, use dois dedos ao mesmo tempo em algum quadro.'
    $it=@(); 1..20 | ForEach-Object { $it+=@{T="$_";A='T'} }
    $g=New-TargetGrid $it 5
    foreach($b in $g.Children){ $b.Add_TouchDown({ param($s,$e) Mark-Target $s }) }
    Run-TargetTest 'touch' $g 20 'Touch com defeito'
}

$script:MciLog=@()
function Mci([string]$c){
    $sb=New-Object Text.StringBuilder 256
    $r=[MobNative]::mciSendString($c,$sb,256,[IntPtr]::Zero)
    if($r -ne 0){ $e=New-Object Text.StringBuilder 256; [void][MobNative]::mciGetErrorString($r,$e,256); $script:MciLog+=("mci '{0}' -> {1}" -f $c,$e.ToString()) }
    return $r
}
function Start-Rec {
    [void](Mci 'close mobrec')
    $r=Mci 'open new type waveaudio alias mobrec'
    if($r -ne 0){ return $false }
    [void](Mci 'set mobrec time format ms'); [void](Mci 'set mobrec bitspersample 16'); [void](Mci 'set mobrec channels 1'); [void](Mci 'set mobrec samplespersec 44100')
    return ((Mci 'record mobrec') -eq 0)
}
function Stop-Rec([string]$file){
    Remove-Item $file -ErrorAction SilentlyContinue
    [void](Mci 'stop mobrec'); [void](Mci ("save mobrec `"$file`"")); [void](Mci 'close mobrec')
}
function Play-Tone([int]$canal,[string]$nome,[double]$secs=1.6,[bool]$async=$false){
    $f="$Base\tone_$nome.wav"; [WavTool]::WriteTone($f,1000,$secs,$canal)
    $sp=New-Object System.Media.SoundPlayer $f; $sp.Load()
    $script:LastPlayer=$sp   # mantem referencia para o som nao ser cortado
    if($async){ $sp.Play() } else { $sp.PlaySync() }
}
# toca um tom (canal 0/1/2) e mede o que o microfone ouviu
function Measure-Loop([int]$canal,[string]$nome,[double]$base){
    $f="$Base\rec_$nome.wav"
    if(-not (Start-Rec)){ return -1 }
    Wait-UI 250; Play-Tone $canal $nome 1.8 $true; Wait-UI 2100; Stop-Rec $f
    if(-not (Test-Path $f)){ return -1 }
    $l=[WavTool]::Level($f); return $l[0]
}

function T-Audio {
    Set-Screen 'Alto-falantes e microfone' 'Automático: o volume vai a 100% (sem mudo) e o notebook toca um tom em cada lado enquanto o microfone escuta. Fique em silêncio. Só pergunta se algo não for detectado.'
    $script:MciLog=@()
    foreach($sv in 'AudioEndpointBuilder','Audiosrv'){ try{ $x=Get-Service $sv -ErrorAction Stop; if($x.Status -ne 'Running'){ Start-Service $sv -ErrorAction SilentlyContinue } }catch{} }
    Wait-UI 300
    $nOut=[MobAudio]::Count(0); $nIn=[MobAudio]::Count(1)
    Log ("Áudio: saídas ativas={0}, entradas ativas={1}" -f $nOut,$nIn)
    if($nOut -eq 0){
        $semDrv=@(Get-CimInstance Win32_PnPEntity | Where-Object { $_.ConfigManagerErrorCode -ne 0 -and ($_.PNPClass -in 'MEDIA','AudioEndpoint' -or $_.Name -match 'audio|áudio|sound|som|Smart Sound|SST|Multimedia|Multimídia|High Definition') } | ForEach-Object { $_.Name })
        $extra= if($semDrv.Count){ ' Dispositivos sem driver: '+($semDrv -join ', ') }else{ '' }
        Live ("Nenhuma saída de áudio ativa no Windows.`r`n`r`nIsso quase sempre é DRIVER de áudio não instalado (Intel Smart Sound / Realtek), não defeito do alto-falante.$extra") 20
        Set-T 'audio' 'FALHA' ("Nenhuma saída de áudio ativa: driver de áudio não instalado ou placa de som desativada.$extra")
        Wait-UI 2500; return
    }
    $vOut=[MobAudio]::Max(0); $vIn= if($nIn -gt 0){[MobAudio]::Max(1)}else{'sem microfone ativo'}
    try{ [MobNative]::VolumeMax() }catch{}
    Log ("Volume saída: $vOut | microfone: $vIn")
    Wait-UI 500
    Live 'Medindo ruído ambiente...' 22
    $f0="$Base\rec_amb.wav"; $amb=0.0; $recOK=($nIn -gt 0) -and (Start-Rec)
    if($recOK){ Wait-UI 1500; Stop-Rec $f0; if(Test-Path $f0){ $amb=([WavTool]::Level($f0))[0] } else { $recOK=$false } }
    $thr=[math]::Max(0.004,$amb*2.5)
    $res=@{}; $det=@()
    if($recOK){
        foreach($par in @(@(1,'ESQUERDO'),@(2,'DIREITO'))){
            Live ("Tocando tom no lado {0} e ouvindo pelo microfone..." -f $par[1]) 22
            $lv=Measure-Loop $par[0] $par[1] $amb
            $res[$par[1]]= ($lv -gt $thr); $det+=("{0}: nível {1:N4} (mín {2:N4})" -f $par[1],$lv,$thr)
        }
    }
    $loopOK=($recOK -and $res['ESQUERDO'] -and $res['DIREITO'])
    $spkL=$res['ESQUERDO']; $spkR=$res['DIREITO']; $micOK=$loopOK; $micTxt=''
    if($loopOK){ $micTxt='o microfone captou o som dos dois alto-falantes' }
    else {
        Log ("Áudio automático inconclusivo: "+($det -join ' | ')+' '+($script:MciLog -join ' | '))
        foreach($par in @(@(1,'ESQUERDO'),@(2,'DIREITO'))){
            if($res[$par[1]]){ continue }
            do{
                Live ("Tocando som SOMENTE no lado {0}... ({1})" -f $par[1],$vOut) 22
                try{ Play-Tone $par[0] ("m"+$par[1]) 1.8 $false }catch{ Log ("Play-Tone: "+$_.Exception.Message) }
                $r=Wait-Click @(("Ouvi no lado {0}" -f $par[1]),'Repetir som','Não ouvi')
            } while($r -eq 'Repetir som')
            $res[$par[1]]=($r -like 'Ouvi*')
        }
        $spkL=$res['ESQUERDO']; $spkR=$res['DIREITO']
        if($nIn -gt 0){
            Live 'Teste do microfone: depois de clicar, FALE ou bata palmas perto do notebook por 4 s.' 20
            [void](Wait-Click @('Iniciar gravação'))
            Live 'Gravando... fale agora!' 30
            if(Start-Rec){ Wait-UI 4000; Stop-Rec $f0; if(Test-Path $f0){ $b2=[WavTool]::Level($f0); $micOK=($b2[0] -gt 0.01 -or $b2[1] -gt 0.08); $micTxt=("captou RMS {0:N4} / pico {1:N2}" -f $b2[0],$b2[1]) } }
            else { $micOK=$false; $micTxt='não foi possível gravar: '+($script:MciLog -join ' | ') }
        } else { $micOK=$false; $micTxt='nenhum microfone ativo no Windows (driver ou microfone desativado)' }
    }
    Remove-Item "$Base\*.wav" -ErrorAction SilentlyContinue
    $d=("Alto-falante esquerdo: {0} | direito: {1} | Microfone: {2} ({3}) | {4}" -f $(if($spkL){'OK'}else{'FALHOU'}),$(if($spkR){'OK'}else{'FALHOU'}),$(if($micOK){'OK'}else{'FALHOU'}),$micTxt,$vOut)
    if($spkL -and $spkR -and $micOK){ Set-T 'audio' 'OK' $d } else { Set-T 'audio' 'FALHA' $d }
}

function T-Webcam {
    if(-not $script:Caps.Cam){ Set-T 'cam' 'ALERTA' 'Webcam não detectada pelo Windows (pode não existir neste modelo)'; return }
    Set-Screen 'Webcam' 'O aplicativo Câmera do Windows abrira por 12 segundos. Olhe a imagem (foco, cor, ausencia de manchas) e acene para a camera. Depois você volta para esta tela sozinho.'
    try{ Start-Process 'microsoft.windows.camera:' }catch{}
    for($i=12;$i -gt 0;$i--){ Wait-UI 1000 }
    Get-Process -Name WindowsCamera -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Wait-UI 600; $Win.Activate() | Out-Null
    Live 'A imagem da câmera estava normal? (sem resposta em 20 s = considerada OK)' 20
    $r=Wait-Click @('Imagem normal','Sem imagem / imagem ruim','Pular') 20
    if($null -eq $r){ $r='Imagem normal' }
    switch($r){ 'Imagem normal'{ Set-T 'cam' 'OK' 'Câmera abriu e imagem confirmada' } 'Pular'{ Set-T 'cam' 'PULADO' 'Pulado pelo técnico' } default{ Set-T 'cam' 'FALHA' 'Sem imagem ou imagem ruim' } }
}

function Get-UsbDrives {
    $l=@()
    try{ Get-Disk -ErrorAction Stop | Where-Object { $_.BusType -eq 'USB' } | Get-Partition -ErrorAction SilentlyContinue | Where-Object { $_.DriveLetter } | ForEach-Object { $l+=("{0}:" -f $_.DriveLetter) } }catch{}
    return $l
}
function T-Usb {
    Set-Screen 'Portas USB' 'Espete um pendrive (ou HD externo) em CADA porta USB, uma de cada vez. Se o pendrive de instalacao ainda estiver ligado, tire e recoloque. Cada porta detectada recebe um teste de velocidade. Clique em Concluir quando tiver testado todas.'
    $prev=@(Get-UsbDrives); $ports=@(); $defeito=$false; $nextPoll=0
    Show-Buttons @('Concluir (todas as portas testadas)','Uma porta não funcionou','Pular')
    $sw=[Diagnostics.Stopwatch]::StartNew()
    while($null -eq $script:Clicked){
        UI-Pump; Start-Sleep -Milliseconds 50
        if($sw.Elapsed.TotalSeconds -ge $nextPoll){
            $nextPoll=$sw.Elapsed.TotalSeconds+1.5
            $now=@(Get-UsbDrives)
            foreach($d in ($now | Where-Object { $prev -notcontains $_ })){
                Live ("Dispositivo detectado em $d ... testando velocidade (64 MB)") 18
                $dt=New-Object DiskTest; $dt.RunAsync("$d\mob_usb_test.bin",64MB,$false)
                while(-not $dt.Done){ UI-Pump; Start-Sleep -Milliseconds 80 }
                $ports+=("Porta {0}: {1}  escrita {2:N0} MB/s  leitura {3:N0} MB/s{4}" -f ($ports.Count+1),$d,$dt.WriteMBs,$dt.ReadMBs,$(if($dt.Err -or $dt.Errors){'  ERRO DE DADOS'}else{''}))
                Log $ports[-1]
            }
            $prev=$now
            Live (("Aguardando pendrive na próxima porta...`r`n`r`n")+($ports -join "`r`n")) 17
        }
    }
    $c=$script:Clicked; Clear-Buttons
    $txt=$ports -join ' | '
    if($c -eq 'Pular'){ Set-T 'usb' 'PULADO' 'Pulado pelo técnico' }
    elseif($c -like 'Uma porta*'){ Set-T 'usb' 'FALHA' ("Técnico reportou porta com defeito. Portas ok: "+$txt) }
    elseif($ports.Count -eq 0){ Set-T 'usb' 'ALERTA' 'Nenhuma porta foi testada' }
    elseif($txt -match 'ERRO DE DADOS'){ Set-T 'usb' 'FALHA' $txt }
    else { Set-T 'usb' 'OK' ("{0} porta(s) testada(s): {1}" -f $ports.Count,$txt) }
}

function Get-MonCount { try{ return @(Get-CimInstance -Namespace root/wmi -ClassName WmiMonitorID -ErrorAction Stop).Count }catch{ return [Windows.Forms.Screen]::AllScreens.Count } }
function T-Video {
    Set-Screen 'Saída de video externa (HDMI / DisplayPort / VGA / USB-C)' 'Ligue um monitor ou TV na saída de video do notebook. Quando o Windows detectar, uma imagem aparecera no monitor externo. Teste cada saída que o notebook tiver.'
    $base=Get-MonCount; $res=@(); $bad=$false; $nextPoll=0
    Show-Buttons @('Concluir','Pular')
    $sw=[Diagnostics.Stopwatch]::StartNew(); $esperaSaida=$false
    while($null -eq $script:Clicked){
        UI-Pump; Start-Sleep -Milliseconds 100
        if($sw.Elapsed.TotalSeconds -lt $nextPoll){ continue }
        $nextPoll=$sw.Elapsed.TotalSeconds+2
        $cnt=Get-MonCount
        if($esperaSaida){ if($cnt -le $base){ $esperaSaida=$false; Live ((($res -join "`r`n"))+"`r`n`r`nPronto. Ligue em OUTRA saída ou clique em Concluir.") 17 }; continue }
        if($cnt -gt $base){
            Live 'Monitor externo detectado. Estendendo a area de trabalho...' 18
            Start-Process DisplaySwitch.exe '/extend'; Wait-UI 3000
            $ext=[Windows.Forms.Screen]::AllScreens | Where-Object { -not $_.Primary } | Select-Object -First 1
            $w=$null
            if($ext){
                $w=New-Object Windows.Window; $w.WindowStyle='None'; $w.WindowStartupLocation='Manual'; $w.Left=$ext.Bounds.Left; $w.Top=$ext.Bounds.Top; $w.Width=$ext.Bounds.Width; $w.Height=$ext.Bounds.Height; $w.Background=(Br '#103A7A'); $w.Topmost=$true
                $t=New-Object Windows.Controls.TextBlock; $t.Text="MOB-CHECK`r`nSAIDA DE VIDEO OK"; $t.FontSize=60; $t.Foreground=(Br '#FFFFFF'); $t.TextAlignment='Center'; $t.HorizontalAlignment='Center'; $t.VerticalAlignment='Center'; $w.Content=$t
                $w.Show()
            }
            $Win.Activate() | Out-Null
            $r=Wait-Click @('Imagem OK no monitor externo','Sem imagem / falha nesta saída')
            if($w){ $w.Close() }
            $n=$res.Count+1
            if($r -like 'Imagem OK*'){ $res+="Saída ${n}: OK" } else { $res+="Saída ${n}: FALHOU"; $bad=$true }
            Log $res[-1]; Start-Process DisplaySwitch.exe '/internal'
            $esperaSaida=$true; Show-Buttons @('Concluir','Pular')
            Live ((($res -join "`r`n"))+"`r`n`r`nDesconecte o monitor. Depois ligue em OUTRA saída ou clique em Concluir.") 17
        } elseif($res.Count -eq 0){ Live 'Aguardando monitor externo...' 20 }
    }
    $c=$script:Clicked; Clear-Buttons
    if($c -eq 'Pular'){ Set-T 'video' 'PULADO' 'Pulado pelo técnico' }
    elseif($res.Count -eq 0){ Set-T 'video' 'ALERTA' 'Nenhuma saída de video foi testada' }
    elseif($bad){ Set-T 'video' 'FALHA' ($res -join ' | ') }
    else { Set-T 'video' 'OK' ($res -join ' | ') }
}

function T-Carregador {
    if(-not $script:HasBat){ Set-T 'carg' 'PULADO' 'Sem bateria - teste de carregador não se aplica'; return }
    Set-Screen 'Carregador e carga da bateria' 'Siga as instrucoes: o teste detecta sozinho quando o carregador e removido e recolocado.'
    $ps={ [Windows.Forms.SystemInformation]::PowerStatus }
    $okDesl=$false; $okLiga=$false
    $ordem= if((& $ps).PowerLineStatus -eq 'Online'){ @('Offline','Online') } else { @('Online','Offline') }
    $log=@()
    foreach($alvo in $ordem){
        $instr= if($alvo -eq 'Offline'){'DESCONECTE o carregador do notebook'}else{'CONECTE o carregador ao notebook'}
        $ui_InstrTxt.Text=$instr+' (aguardando até 90 s)'; Show-Buttons @('Falhou / não detectou','Pular')
        $sw=[Diagnostics.Stopwatch]::StartNew(); $ok=$false
        while($null -eq $script:Clicked -and $sw.Elapsed.TotalSeconds -lt 90){
            UI-Pump; Start-Sleep -Milliseconds 150; $ui_Barra.Value=$sw.Elapsed.TotalSeconds*100/90
            $st=(& $ps)
            Live ("{0}`r`n`r`nEstado atual: {1}   Carga: {2}%" -f $instr,$(if($st.PowerLineStatus -eq 'Online'){'COM carregador'}else{'SEM carregador (bateria)'}),[int]($st.BatteryLifePercent*100)) 22
            if($st.PowerLineStatus -eq $alvo){ $ok=$true; break }
        }
        $c=$script:Clicked; Clear-Buttons
        if($c -eq 'Pular'){ Set-T 'carg' 'PULADO' 'Pulado pelo técnico'; return }
        $log+=("{0}: {1}" -f $(if($alvo -eq 'Offline'){'Remoção'}else{'Conexão'}),$(if($ok){'detectada'}else{'NÃO detectada'}))
        if(-not $ok){ break }
        Wait-UI 1500
    }
    if($log.Count -eq 2 -and $log[0] -notmatch 'NÃO' -and $log[1] -notmatch 'NÃO'){
        $st=(& $ps); Set-T 'carg' 'OK' (($log -join ' | ')+" | carga {0}%" -f [int]($st.BatteryLifePercent*100))
    } else { Set-T 'carg' 'FALHA' ($log -join ' | ') }
}

function T-Tampa {
    Set-Screen 'Tampa (sensor do lid)' 'FECHE a tampa do notebook por 2 segundos e ABRA de novo. O teste detecta o sensor sozinho. (A suspensão por fechar a tampa foi desativada so durante o teste.)'
    powercfg /setacvalueindex SCHEME_CURRENT SUB_BUTTONS LIDACTION 0 | Out-Null; powercfg /setdcvalueindex SCHEME_CURRENT SUB_BUTTONS LIDACTION 0 | Out-Null; powercfg /setactive SCHEME_CURRENT | Out-Null
    if(-not $script:Lid){
        $script:Lid=New-Object LidMonitor
        $h=(New-Object Windows.Interop.WindowInteropHelper $Win).Handle
        $script:LidOK=$script:Lid.Register($h)
        [Windows.Interop.HwndSource]::FromHwnd($h).AddHook($script:Lid.GetHook())
    }
    if(-not $script:LidOK){ Set-T 'lid' 'ALERTA' 'Não foi possível registrar o monitor de tampa (equipamento sem sensor ou desktop)'; return }
    Wait-UI 700; $script:Lid.Closed=0; $script:Lid.Opened=0
    Show-Buttons @('Não possui tampa / pular')
    $sw=[Diagnostics.Stopwatch]::StartNew(); $fechou=$false; $ok=$false
    while($null -eq $script:Clicked -and $sw.Elapsed.TotalSeconds -lt 120){
        UI-Pump; Start-Sleep -Milliseconds 100; $ui_Barra.Value=$sw.Elapsed.TotalSeconds*100/120
        if($script:Lid.Closed -ge 1 -and -not $fechou){ $fechou=$true; $script:Lid.Opened=0 }
        if($fechou -and $script:Lid.Opened -ge 1){ $ok=$true; break }
        Live ("Tampa fechada detectada: {0}`r`nTampa reaberta detectada: {1}" -f $(if($fechou){'SIM'}else{'aguardando...'}),$(if($ok){'SIM'}else{'aguardando...'})) 22
    }
    $c=$script:Clicked; Clear-Buttons
    powercfg /setacvalueindex SCHEME_CURRENT SUB_BUTTONS LIDACTION 1 | Out-Null; powercfg /setdcvalueindex SCHEME_CURRENT SUB_BUTTONS LIDACTION 1 | Out-Null; powercfg /setactive SCHEME_CURRENT | Out-Null
    $Win.Activate() | Out-Null
    if($ok){ Set-T 'lid' 'OK' 'Fechamento e abertura da tampa detectados' }
    elseif($c){ Set-T 'lid' 'PULADO' 'Pulado pelo técnico' }
    elseif($fechou){ Set-T 'lid' 'FALHA' 'Tampa fechou mas a reabertura não foi detectada' }
    else { Set-T 'lid' 'FALHA' 'Sensor da tampa não respondeu em 120 s' }
}

function T-Luz {
    Set-Screen 'Luz do teclado (backlight)' 'Acione a luz do teclado (normalmente Fn + uma tecla com simbolo de luz, ou F5/F9/F10). Ela acende?'
    $r=Wait-Click @('Acende','Não acende','Este modelo não possui','Pular')
    switch($r){ 'Acende'{ Set-T 'luz' 'OK' 'Luz do teclado funcionando' } 'Não acende'{ Set-T 'luz' 'FALHA' 'Luz do teclado não acende' } default{ Set-T 'luz' 'PULADO' 'Não se aplica / pulado' } }
}

# =====================================================================
#  RELATORIO
# =====================================================================
# o que significa cada falha/alerta e o que fazer
function Get-Recomendacao($t){
    $d=[string]$t.Detalhe
    if($d -match 'erro do programa'){ return 'O teste não pôde ser concluído por um erro do programa. Repita o teste; não indica defeito no equipamento.' }
    switch($t.Id){
        'cpu'   { if($d -match 'cálculo'){ return 'Processador ou memória instável sob carga. Testar a RAM em outro slot/pente; se persistir, defeito na placa-mãe/CPU.' }
                  if($d -match 'Superaquec|Temperatura'){ return 'Temperatura elevada. Limpar cooler e dissipador e trocar a pasta térmica.' }
                  return 'CPU reduzindo a velocidade sob carga. Verificar cooler/pasta térmica e se o carregador original está conectado.' }
        'ram'   { if($d -match 'erro de dados'){ return 'Memória RAM com defeito. Reencaixar/limpar os contatos e retestar; se persistir, substituir o pente.' } return 'Fechar outros programas e repetir o teste.' }
        'disco' { if($d -match 'corromp|E/S'){ return 'Disco com erro de leitura/gravação. Substituir o SSD/HD.' } if($d -match 'lento'){ return 'Disco abaixo da velocidade esperada. Verificar saúde do SSD e se está no modo correto (NVMe/AHCI).' } return 'Saúde do disco (SMART) comprometida. Fazer backup e programar a troca do disco.' }
        'bat'   { if($d -match 'fim da vida'){ return 'Bateria com menos de 60% da capacidade original. Substituir a bateria.' } return 'Bateria desgastada (60-80% da capacidade). Informar o cliente / avaliar troca.' }
        'rede'  { if($d -match 'Nenhum adaptador'){ return 'Placa Wi-Fi ausente ou sem driver. Verificar o Gerenciador de Dispositivos e a placa Wi-Fi/antenas.' } if($d -match 'não está conectado'){ return 'A placa Wi-Fi existe mas não conectou. Conectar numa rede e repetir; verificar antenas.' } return 'Sinal fraco, perda de pacotes ou velocidade baixa. Verificar cabos de antena da tela e a placa Wi-Fi.' }
        'bt'    { return 'Bluetooth não encontrado ou com erro. Verificar driver e a placa Wi-Fi/Bluetooth (geralmente é o mesmo módulo).' }
        'gpu'   { if($d -match 'Basic Display'){ return 'Driver de vídeo não instalado. Instalar o driver Intel/AMD/NVIDIA do fabricante e retestar.' } return 'Vídeo com erro ou renderização fraca. Verificar driver de vídeo e a GPU.' }
        'drv'   { return 'Há dispositivos sem driver. Instalar os drivers do fabricante (ou via Windows Update) e retestar.' }
        'sens'  { return 'Algum componente não foi detectado pelo Windows. Verificar se o modelo possui o item e se o driver está instalado.' }
        'comb'  { return 'Instabilidade com tudo em carga máxima: suspeitar de fonte/carregador, aquecimento ou memória. Limpar o sistema de refrigeração e retestar.' }
        'tela'  { return 'Defeito visual no painel (pixel morto, mancha ou linha). Avaliar troca da tela ou do flat.' }
        'tec'   { return 'Teclas sem resposta. Verificar flat do teclado e, se necessário, substituir o teclado.' }
        'tp'    { return 'Touchpad/botões sem resposta. Verificar flat do touchpad e driver (I2C HID).' }
        'touch' { return 'Tela touch sem resposta em parte da área. Verificar digitalizador/driver.' }
        'audio' { if($d -match 'driver'){ return 'Sem saída de áudio no Windows: instalar o driver de áudio do fabricante (Intel Smart Sound + Realtek) e retestar.' } if($d -match 'Microfone: FALHOU'){ return 'Alto-falantes OK, mas o microfone não captou som. Verificar o microfone/flat da tela e o driver.' } return 'Alto-falante sem som em um ou dois lados. Verificar conectores dos alto-falantes; se persistir, substituir.' }
        'cam'   { return 'Webcam sem imagem ou com imagem ruim. Verificar flat da câmera, privacidade/obturador e driver.' }
        'usb'   { return 'Porta USB com defeito ou erro de dados. Verificar a porta e a placa de USB.' }
        'video' { return 'Saída de vídeo externa sem imagem. Testar com outro cabo/monitor; se persistir, defeito no conector.' }
        'carg'  { return 'Notebook não detectou o carregador. Verificar carregador, cabo e conector DC/USB-C.' }
        'lid'   { return 'Sensor de tampa não respondeu. Verificar o sensor hall/ímã da tampa.' }
        'luz'   { return 'Luz do teclado não acende. Verificar atalho Fn, flat do backlight e o teclado.' }
    }
    return 'Verificar o componente indicado.'
}

function Build-Report {
    $enc={ param($x) [System.Net.WebUtility]::HtmlEncode([string]$x) }
    $falhas=@($Tests | Where-Object Status -eq 'FALHA'); $alertas=@($Tests | Where-Object Status -eq 'ALERTA')
    $oks=@($Tests | Where-Object Status -eq 'OK'); $pul=@($Tests | Where-Object Status -eq 'PULADO')
    $veredito= if($falhas.Count){'REPROVADO'}elseif($alertas.Count){'APROVADO COM RESSALVAS'}else{'APROVADO'}
    $corV= if($falhas.Count){'#E5484D'}elseif($alertas.Count){'#F5A524'}else{'#17C964'}
    $cores=@{OK='#17C964';ALERTA='#F5A524';FALHA='#E5484D';PULADO='#8A9BB4';PENDENTE='#8A9BB4';RODANDO='#1E8BFF'}
    $rot=@{OK='OK';ALERTA='ALERTA';FALHA='FALHA';PULADO='PULADO';PENDENTE='NÃO FEITO';RODANDO='NÃO CONCLUÍDO'}
    $inf=($script:Info.GetEnumerator() | ForEach-Object { "<div class='kv'><span>{0}</span><b>{1}</b></div>" -f (& $enc $_.Key),(& $enc $_.Value) }) -join "`n"
    $prob=@($falhas)+@($alertas)
    $probHtml= if($prob.Count){
        ($prob | ForEach-Object { "<div class='prob' style='border-left-color:{0}'><div class='ph'><span class='chip' style='background:{0}'>{1}</span><b>{2}</b></div><div class='pd'><span>O que foi encontrado:</span> {3}</div><div class='pr'><span>O que fazer:</span> {4}</div></div>" -f $cores[$_.Status],$rot[$_.Status],(& $enc $_.Nome),(& $enc $_.Detalhe),(& $enc (Get-Recomendacao $_)) }) -join "`n"
    } else { "<div class='okall'>Nenhuma falha ou alerta encontrado. Todos os testes realizados passaram.</div>" }
    $lin=($Tests | ForEach-Object { "<tr><td class='tn'>{0}</td><td><span class='chip' style='background:{1}'>{2}</span></td><td class='dt'>{3}</td><td class='du'>{4}s</td></tr>" -f (& $enc $_.Nome),$cores[$_.Status],$rot[$_.Status],(& $enc $_.Detalhe),$_.Seg }) -join "`n"
    $data=Get-Date -Format 'dd/MM/yyyy HH:mm'
    $html=@"
<!doctype html><html lang="pt-BR"><head><meta charset="utf-8"><title>MOB-CHECK PC - $(& $enc $script:Serial)</title>
<style>
@page{size:A4;margin:12mm 11mm 14mm}
*{box-sizing:border-box;-webkit-print-color-adjust:exact;print-color-adjust:exact}
body{font-family:'Segoe UI',Arial,sans-serif;color:#13233A;margin:0;font-size:12px}
.hero{background:#051222;border-radius:14px;padding:18px 22px;display:flex;align-items:center;justify-content:space-between;color:#fff}
.hero img{height:92px}
.hero .t{text-align:right}.hero .t h1{margin:0;font-size:22px;letter-spacing:.5px}.hero .t h1 span{color:#35B6FF}
.hero .t div{color:#8FA6C3;font-size:11px;margin-top:4px}
.sum{display:flex;gap:10px;margin:14px 0}
.ver{flex:1.6;border-radius:12px;padding:14px 18px;color:#fff;background:$corV}
.ver small{display:block;opacity:.85;font-size:11px;text-transform:uppercase;letter-spacing:1px}.ver b{font-size:24px}
.cnt{flex:1;border-radius:12px;padding:12px 14px;background:#F1F5FB;border:1px solid #DCE5F2}
.cnt small{display:block;color:#5D7290;font-size:10px;text-transform:uppercase;letter-spacing:1px}.cnt b{font-size:24px}
h2{font-size:14px;margin:18px 0 8px;color:#0B3B74;text-transform:uppercase;letter-spacing:1px;border-bottom:2px solid #1E8BFF;padding-bottom:4px}
.grid{display:grid;grid-template-columns:1fr 1fr;gap:6px 18px}
.kv{display:flex;justify-content:space-between;border-bottom:1px solid #E4EAF3;padding:4px 0}.kv span{color:#5D7290}.kv b{text-align:right;max-width:65%}
.prob{border:1px solid #E4EAF3;border-left:5px solid;border-radius:10px;padding:9px 12px;margin-bottom:8px;page-break-inside:avoid}
.ph{display:flex;align-items:center;gap:8px;font-size:13px;margin-bottom:4px}
.pd,.pr{margin-top:3px;line-height:1.4}.pd span,.pr span{font-weight:700;color:#0B3B74}
.okall{background:#E9FBF1;border:1px solid #B7EDCF;color:#0E7A3E;padding:12px;border-radius:10px;font-weight:600}
.chip{display:inline-block;color:#fff;border-radius:20px;padding:2px 10px;font-size:10px;font-weight:700;letter-spacing:.5px;white-space:nowrap}
table{border-collapse:collapse;width:100%}th{background:#0B1A2E;color:#fff;text-align:left;font-size:11px;padding:7px 8px}
td{border-bottom:1px solid #E4EAF3;padding:6px 8px;vertical-align:top}tr:nth-child(even) td{background:#F7F9FC}
td.tn{font-weight:600;width:24%}td.dt{color:#3A4E6B;font-size:11px}td.du{color:#5D7290;width:6%;text-align:right}
.foot{margin-top:18px;display:flex;justify-content:space-between;color:#8A9BB4;font-size:10px;border-top:1px solid #E4EAF3;padding-top:8px}
.sign{margin-top:26px;display:flex;gap:40px}.sign div{flex:1;border-top:1px solid #9AABC3;padding-top:4px;color:#5D7290;font-size:10px;text-align:center}
</style></head><body>
<div class="hero"><img src="data:image/jpeg;base64,$LogoB64"><div class="t"><h1>MOB-CHECK <span>PC</span></h1><div>Laudo de diagnóstico de notebook<br>$data</div></div></div>
<div class="sum">
<div class="ver"><small>Resultado</small><b>$veredito</b></div>
<div class="cnt"><small>Falhas</small><b style="color:#E5484D">$($falhas.Count)</b></div>
<div class="cnt"><small>Alertas</small><b style="color:#F5A524">$($alertas.Count)</b></div>
<div class="cnt"><small>OK</small><b style="color:#17C964">$($oks.Count)</b></div>
<div class="cnt"><small>Pulados</small><b style="color:#8A9BB4">$($pul.Count)</b></div>
</div>
<h2>Equipamento</h2><div class="grid">$inf</div>
<h2>Falhas e alertas</h2>$probHtml
<h2>Todos os testes</h2>
<table><tr><th>Teste</th><th>Resultado</th><th>Detalhes</th><th>Tempo</th></tr>$lin</table>
<div class="sign"><div>Técnico responsável</div><div>Data</div></div>
<div class="foot"><span>MOBIT Soluções - Assistência Técnica</span><span>Modo: $($Cfg.Nome) | S/N $(& $enc $script:Serial)</span></div>
</body></html>
"@
    $nome="MOB-CHECK_{0}_{1}" -f ($script:Serial -replace '[^A-Za-z0-9\-]','_'),(Get-Date -Format 'yyyyMMdd-HHmm')
    $script:ReportHtml="$RelDir\$nome.html"
    [IO.File]::WriteAllText($script:ReportHtml,$html,(New-Object Text.UTF8Encoding($true)))
    $Tests | Select-Object Id,Nome,Status,Detalhe,Seg | ConvertTo-Json | Set-Content "$RelDir\$nome.json" -Encoding UTF8
    # PDF pelo Microsoft Edge (ja vem no Windows 11)
    $script:ReportFile=$script:ReportHtml
    $pdf="$RelDir\$nome.pdf"
    $edge=@("${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe","$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1
    if($edge){
        try{
            $prof="$env:TEMP\mob-edge-pdf"; New-Item -ItemType Directory -Force -Path $prof | Out-Null
            $uri=([Uri]$script:ReportHtml).AbsoluteUri
            $pr=Start-Process $edge -ArgumentList @('--headless','--disable-gpu','--no-first-run','--no-pdf-header-footer','--print-to-pdf-no-header',"--user-data-dir=`"$prof`"","--print-to-pdf=`"$pdf`"",$uri) -PassThru -WindowStyle Hidden
            $sw=[Diagnostics.Stopwatch]::StartNew(); while(-not $pr.HasExited -and $sw.Elapsed.TotalSeconds -lt 60){ UI-Pump; Start-Sleep -Milliseconds 200 }
            if(-not $pr.HasExited){ try{ $pr.Kill() }catch{} }
            if((Test-Path $pdf) -and (Get-Item $pdf).Length -gt 5000){ $script:ReportFile=$pdf; Log "PDF gerado: $pdf" } else { Log 'Não foi possível gerar o PDF; relatório salvo em HTML.' }
        }catch{ Log ("PDF: "+$_.Exception.Message) }
    } else { Log 'Microsoft Edge não encontrado; relatório salvo em HTML.' }
    Copy-Item $script:ReportFile ("$RelDir\ultimo-relatorio"+[IO.Path]::GetExtension($script:ReportFile)) -Force
    return $veredito
}

# =====================================================================
#  FLUXO PRINCIPAL
# =====================================================================
Add-T info  'Identificação do equipamento' 1
Add-T cpu   'CPU - estresse e temperatura' 1
Add-T ram   'Memória RAM' 1
Add-T disco 'Disco - SMART e velocidade' 1
Add-T bat   'Bateria - saúde' 1
Add-T rede  'Wi-Fi / rede' 1
Add-T bt    'Bluetooth' 1
Add-T gpu   'Vídeo / GPU' 1
Add-T drv   'Drivers e dispositivos' 1
Add-T sens  'Webcam / mic / sensores (detecção)' 1
Add-T comb  'Estresse combinado' 1
Add-T tela  'Tela e brilho' 2
Add-T tec   'Teclado' 2
Add-T tp    'Touchpad e botões' 2
Add-T touch 'Tela touch' 2
Add-T audio 'Alto-falantes e microfone' 2
Add-T cam   'Webcam' 2
Add-T usb   'Portas USB' 2
Add-T video 'Saída de vídeo externa' 2
Add-T carg  'Carregador' 2
Add-T lid   'Tampa (lid)' 2
Add-T luz   'Luz do teclado' 2
Refresh-List

$Win.Show(); $Win.Activate() | Out-Null
Log 'MOB-CHECK PC iniciado'
Set-Screen 'Bem-vindo ao MOB-CHECK PC' 'Fase 1 roda sozinha (CPU, RAM, disco, bateria, rede, Bluetooth, vídeo, drivers e estresse combinado). Depois a Fase 2 pede ações suas: tela, teclado, touchpad, áudio, câmera, USB, HDMI, carregador, tampa. Sem resposta em 6 s, inicia o teste COMPLETO.'
$modo= if($Rapido){'R'} elseif($Completo){'C'} else { $r=Wait-Click @('Teste COMPLETO','Teste RÁPIDO') 6; if($r -like '*PIDO*'){'R'}else{'C'} }
if($modo -eq 'R'){ $Cfg=@{ Cpu=30; RamPct=50; RamLoops=1; DiscoGB=0.5; Comb=20; Nome='RAPIDO' } }
Log ("Modo: "+$Cfg.Nome)

# --- fase 1
Run-T 'info'  { T-Info }
Run-T 'cpu'   { T-Cpu }
Run-T 'ram'   { T-Ram }
Run-T 'disco' { T-Disco }
Run-T 'bat'   { T-Bateria }
Run-T 'rede'  { T-Rede }
Run-T 'bt'    { T-Bluetooth }
Run-T 'gpu'   { T-Gpu }
Run-T 'drv'   { T-Drivers }
Run-T 'sens'  { T-Sensores }
Run-T 'comb'  { T-Combinado }

Set-Screen 'Fase 1 concluída' 'Os testes automáticos terminaram. Iniciando a Fase 2 (testes que podem pedir uma ação sua)...'
Wait-UI 2500

# --- fase 2
Run-T 'tela'  { T-Tela }
Run-T 'tec'   { T-Teclado }
Run-T 'tp'    { T-Touchpad }
Run-T 'touch' { T-Touch }
Run-T 'audio' { T-Audio }
Run-T 'cam'   { T-Webcam }
Run-T 'usb'   { T-Usb }
Run-T 'video' { T-Video }
Run-T 'carg'  { T-Carregador }
Run-T 'lid'   { T-Tampa }
Run-T 'luz'   { T-Luz }

# --- fim
Set-Screen 'Gerando o laudo em PDF...' 'Montando o relatório com todos os testes.'
$ver=Build-Report
New-Item -ItemType File -Force -Path "$Base\done.flag" | Out-Null
Cleanup
$corFinal= if($ver -eq 'REPROVADO'){'#FF5C6C'}elseif($ver -like '*RESSALVAS'){'#FFC247'}else{'#2EE59D'}
Set-Screen 'Teste concluído' ("Laudo salvo em: "+$script:ReportFile)
$sp=New-Object Windows.Controls.StackPanel; $sp.VerticalAlignment='Center'; $sp.HorizontalAlignment='Center'
$tb=New-Object Windows.Controls.TextBlock; $tb.Text=$ver; $tb.FontSize=58; $tb.FontWeight='Black'; $tb.Foreground=(Br $corFinal); $tb.HorizontalAlignment='Center'
$nf=@($Tests | Where-Object Status -eq 'FALHA').Count; $na=@($Tests | Where-Object Status -eq 'ALERTA').Count; $nok=@($Tests | Where-Object Status -eq 'OK').Count
$t2=New-Object Windows.Controls.TextBlock; $t2.Text=("{0} OK   •   {1} alerta(s)   •   {2} falha(s)" -f $nok,$na,$nf); $t2.FontSize=22; $t2.Foreground=(Br '#A9BCD6'); $t2.HorizontalAlignment='Center'; $t2.Margin='0,10,0,0'
[void]$sp.Children.Add($tb); [void]$sp.Children.Add($t2)
foreach($t in @($Tests | Where-Object { $_.Status -in 'FALHA','ALERTA' })){
    $x=New-Object Windows.Controls.TextBlock; $x.Text=("{0}  {1}: {2}" -f $Icone[$t.Status],$t.Nome,(Get-Recomendacao $t)); $x.FontSize=15; $x.Foreground=(Br $Cor[$t.Status]); $x.TextWrapping='Wrap'; $x.MaxWidth=1000; $x.Margin='0,8,0,0'
    [void]$sp.Children.Add($x)
}
$ui_Painel.Content=$sp; $ui_Barra.Value=100
Log "Veredito: $ver"
try{ Start-Process $script:ReportFile }catch{}
while($true){
    $r=Wait-Click @('Abrir laudo (PDF)','Copiar para pendrive','Refazer testes','Fechar','Apagar redes Wi-Fi e fechar')
    switch($r){
        'Abrir laudo (PDF)' { Start-Process $script:ReportFile }
        'Copiar para pendrive' {
            $u=@(Get-UsbDrives); if($u.Count){ foreach($d in $u){ New-Item -ItemType Directory -Force -Path "$d\MOB-RELATORIOS" | Out-Null; Copy-Item $script:ReportFile,$script:ReportHtml "$d\MOB-RELATORIOS\" -Force }; Log ("Laudo copiado para: "+($u -join ', ')) } else { Log 'Nenhum pendrive encontrado' }
        }
        'Refazer testes' { Remove-Item "$Base\done.flag" -ErrorAction SilentlyContinue; try{ $script:Mutex.ReleaseMutex() }catch{}; Start-Process powershell -ArgumentList "-NoProfile -ExecutionPolicy Bypass -STA -File `"$PSCommandPath`"$extra"; $Win.Close() }
        'Fechar' { $Win.Close() }
        'Apagar redes Wi-Fi e fechar' {
            # remove as redes Wi-Fi salvas neste notebook (use antes de entregar ao cliente)
            $o=netsh wlan delete profile name=* i=*; Log ("Perfis Wi-Fi removidos: "+($o -join ' '))
            Remove-Item 'HKLM:\SOFTWARE\MOB' -Recurse -Force -ErrorAction SilentlyContinue
            Wait-UI 1500; $Win.Close()
        }
    }
}
