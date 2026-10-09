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

public class RamTest {
    public long Tested; public long Errors; public volatile int Pct; public volatile bool Done; public volatile bool Cancel;
    public void RunAsync(long target,int loops){ var t=new Thread(()=>Run(target,loops)); t.IsBackground=true; t.Start(); }
    void Run(long target,int loops){
        try{
            int chunkLongs=32*1024*1024; // 256 MB
            int n=(int)(target/((long)chunkLongs*8)); if(n<1) n=1;
            var list=new List<long[]>();
            for(int i=0;i<n;i++){ try{ list.Add(new long[chunkLongs]); }catch(OutOfMemoryException){ break; } }
            Tested=(long)list.Count*chunkLongs*8;
            long[] pats={ unchecked((long)0xAAAAAAAAAAAAAAAAUL), 0x5555555555555555L, 0L, -1L };
            long mul=unchecked((long)0x9E3779B97F4A7C15UL);
            int steps=loops*(pats.Length+2); int step=0;
            for(int l=0;l<loops && !Cancel;l++){
                foreach(var p in pats){
                    if(Cancel) break;
                    foreach(var a in list){ for(int i=0;i<a.Length;i++) a[i]=p; }
                    foreach(var a in list){ for(int i=0;i<a.Length;i++) if(a[i]!=p) Errors++; }
                    step++; Pct=Math.Min(100,step*100/steps);
                }
                if(Cancel) break;
                for(int c=0;c<list.Count;c++){ var a=list[c]; long b=(long)c*a.Length; for(int i=0;i<a.Length;i++) a[i]=unchecked((b+i)*mul); }
                for(int c=0;c<list.Count;c++){ var a=list[c]; long b=(long)c*a.Length; for(int i=0;i<a.Length;i++) if(a[i]!=unchecked((b+i)*mul)) Errors++; }
                step++; Pct=Math.Min(100,step*100/steps);
                ulong x=88172645463325252UL;
                foreach(var a in list){ for(int i=0;i<a.Length;i++){ x^=x<<13; x^=x>>7; x^=x<<17; a[i]=(long)x; } }
                x=88172645463325252UL;
                foreach(var a in list){ for(int i=0;i<a.Length;i++){ x^=x<<13; x^=x>>7; x^=x<<17; if(a[i]!=(long)x) Errors++; } }
                step++; Pct=Math.Min(100,step*100/steps);
            }
            list.Clear();
        }catch(Exception){ Errors+=1; }
        Done=true;
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
'@

# mantem a maquina acordada durante todo o teste
[void][MobNative]::SetThreadExecutionState([uint32]2147483651)   # ES_CONTINUOUS|ES_SYSTEM_REQUIRED|ES_DISPLAY_REQUIRED (0x80000003 vira numero negativo no PowerShell)

# ---------- janela principal (WPF) ----------
[xml]$XAML = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="MOB-CHECK PC" WindowStyle="None" WindowState="Maximized" ResizeMode="NoResize"
        Background="#0E1217" Foreground="#E8EDF2" FontFamily="Segoe UI">
  <Grid>
    <Grid.RowDefinitions>
      <RowDefinition Height="62"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>
    <Border Grid.Row="0" Background="#151B23" BorderBrush="#232C38" BorderThickness="0,0,0,1">
      <Grid Margin="22,0">
        <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
          <TextBlock Text="MOB" FontSize="26" FontWeight="Black" Foreground="#4DA3FF"/>
          <TextBlock Text="-CHECK PC" FontSize="26" FontWeight="Light"/>
          <TextBlock x:Name="Sub" Margin="22,6,0,0" FontSize="14" Foreground="#8A97A6" VerticalAlignment="Center"/>
        </StackPanel>
        <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Center">
          <TextBlock x:Name="Resumo" FontSize="15" Foreground="#8A97A6" Margin="0,0,20,0" VerticalAlignment="Center"/>
          <Button x:Name="BtnSair" Content="Sair" Padding="14,4" Background="#232C38" Foreground="#E8EDF2" BorderThickness="0"/>
        </StackPanel>
      </Grid>
    </Border>
    <Grid Grid.Row="1">
      <Grid.ColumnDefinitions><ColumnDefinition Width="350"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
      <Border Grid.Column="0" Background="#121820" BorderBrush="#232C38" BorderThickness="0,0,1,0">
        <ScrollViewer VerticalScrollBarVisibility="Auto"><StackPanel x:Name="Lista" Margin="18,14"/></ScrollViewer>
      </Border>
      <Grid Grid.Column="1" Margin="28,18,28,8">
        <Grid.RowDefinitions>
          <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/>
          <RowDefinition Height="*"/><RowDefinition Height="104"/>
        </Grid.RowDefinitions>
        <TextBlock x:Name="Titulo" Grid.Row="0" FontSize="30" FontWeight="SemiBold"/>
        <TextBlock x:Name="InstrTxt" Grid.Row="1" FontSize="18" Foreground="#B7C2CF" TextWrapping="Wrap" Margin="0,8,0,12"/>
        <ProgressBar x:Name="Barra" Grid.Row="2" Height="10" Minimum="0" Maximum="100" Foreground="#4DA3FF" Background="#232C38" BorderThickness="0" Margin="0,0,0,12"/>
        <ContentControl x:Name="Painel" Grid.Row="3"/>
        <TextBox x:Name="LogBox" Grid.Row="4" IsReadOnly="True" Background="#0A0E13" Foreground="#7F8C9A" BorderBrush="#232C38"
                 FontFamily="Consolas" FontSize="12" VerticalScrollBarVisibility="Auto" TextWrapping="NoWrap" Margin="0,8,0,0"/>
      </Grid>
    </Grid>
    <Border Grid.Row="2" Background="#151B23" BorderBrush="#232C38" BorderThickness="0,1,0,0" MinHeight="74">
      <StackPanel x:Name="Botoes" Orientation="Horizontal" HorizontalAlignment="Center" VerticalAlignment="Center" Margin="0,8"/>
    </Border>
  </Grid>
</Window>
'@
$Win = [Windows.Markup.XamlReader]::Load((New-Object Xml.XmlNodeReader $XAML))
foreach($n in 'Sub','Resumo','BtnSair','Lista','Titulo','InstrTxt','Barra','Painel','LogBox','Botoes'){ Set-Variable -Name "ui_$n" -Value $Win.FindName($n) -Scope Script }

$Cor    = @{ OK='#3DDC84'; ALERTA='#FFC247'; FALHA='#FF5C5C'; PULADO='#7C8794'; RODANDO='#4DA3FF'; PENDENTE='#566170' }
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
            $h=New-Object Windows.Controls.TextBlock; $h.FontSize=12; $h.Foreground=(Br '#4DA3FF'); $h.FontWeight='Bold'; $h.Margin='0,12,0,4'
            $h.Text= if($t.Fase -eq 1){'FASE 1 - AUTOMÁTICA'}else{'FASE 2 - COM VOCÊ'}
            [void]$ui_Lista.Children.Add($h); $lastFase=$t.Fase
        }
        $r=New-Object Windows.Controls.TextBlock; $r.FontSize=15; $r.Margin='0,3,0,3'
        $r.Text=("{0}  {1}" -f $Icone[$t.Status],$t.Nome); $r.Foreground=(Br $Cor[$t.Status])
        if($t.Status -eq 'RODANDO'){ $r.FontWeight='Bold' }
        [void]$ui_Lista.Children.Add($r)
    }
    $feitos=@($Tests | Where-Object { $_.Status -notin 'PENDENTE','RODANDO' }).Count
    $ui_Resumo.Text="$feitos / $($Tests.Count) testes"
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
        $b.Content=$l; $b.Margin='7,0'; $b.Padding='24,12'; $b.FontSize=17; $b.MinWidth=150; $b.BorderThickness='0'
        $b.Foreground=(Br '#FFFFFF'); $b.Background=(Br $(if($i -eq 0){'#2F7BD6'}else{'#2A3441'}))
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
    try{ & $sb }catch{ $msg=('Erro interno do teste: '+$_.Exception.Message+' (linha '+$_.InvocationInfo.ScriptLineNumber+')'); Log ($msg+' | '+$_.ScriptStackTrace); Set-T $id 'FALHA' $msg }
    $t.Seg=[int]$sw.Elapsed.TotalSeconds
    if($t.Status -eq 'RODANDO'){ Set-T $id 'ALERTA' 'O teste terminou sem resultado' }
    Clear-Buttons; $script:KeyHook=$null
}

# ---------- utilitarios de hardware ----------
$script:LhmFail=$false; $script:Lhm=$null
function Get-LhmTemp {
    if($script:LhmFail){ return $null }
    try{
        if(-not $script:Lhm){
            $dir="$Base\lhm"; New-Item -ItemType Directory -Force -Path $dir | Out-Null
            if(-not (Test-Path "$dir\LibreHardwareMonitorLib.dll")){
                Add-Type -AssemblyName System.IO.Compression.FileSystem
                foreach($pk in @(@('LibreHardwareMonitorLib','0.9.4'),@('HidSharp','2.1.0'))){
                    $zip="$dir\$($pk[0]).zip"
                    Invoke-WebRequest "https://www.nuget.org/api/v2/package/$($pk[0])/$($pk[1])" -OutFile $zip -UseBasicParsing -TimeoutSec 40
                    $z=[IO.Compression.ZipFile]::OpenRead($zip)
                    foreach($e in $z.Entries){ if($e.FullName -match '^lib/(net472|net45|net35)/[^/]+\.dll$' -and -not (Test-Path "$dir\$($e.Name)")){ [IO.Compression.ZipFileExtensions]::ExtractToFile($e,"$dir\$($e.Name)",$true) } }
                    $z.Dispose()
                }
            }
            foreach($f in 'HidSharp.dll','LibreHardwareMonitorLib.dll'){ if(Test-Path "$dir\$f"){ [void][Reflection.Assembly]::LoadFrom("$dir\$f") } }
            $c=New-Object LibreHardwareMonitor.Hardware.Computer; $c.IsCpuEnabled=$true; $c.Open(); $script:Lhm=$c
        }
        $pk=$null; $mx=$null
        foreach($hw in $script:Lhm.Hardware){
            $hw.Update()
            foreach($sn in $hw.Sensors){
                if([string]$sn.SensorType -eq 'Temperature' -and $sn.Value){
                    if($sn.Name -match 'Package|Tctl|Die'){ $pk=[double]$sn.Value }
                    if($null -eq $mx -or [double]$sn.Value -gt $mx){ $mx=[double]$sn.Value }
                }
            }
        }
        if($pk){ return [math]::Round($pk,1) }; if($mx){ return [math]::Round($mx,1) }
    }catch{ $script:LhmFail=$true; Log ("Sensor de temperatura avançado indisponível: "+$_.Exception.Message) }
    return $null
}
function Get-CpuTemp {
    $t=Get-LhmTemp; if($t){ return $t }
    try{
        $c=Get-Counter '\Thermal Zone Information(*)\Temperature' -ErrorAction Stop
        $m=($c.CounterSamples | ForEach-Object { $_.CookedValue-273.15 } | Where-Object { $_ -gt 10 -and $_ -lt 130 } | Measure-Object -Maximum).Maximum
        if($m){ return [math]::Round($m,1) }
    }catch{}
    try{
        $z=Get-CimInstance -Namespace root/wmi -ClassName MSAcpi_ThermalZoneTemperature -ErrorAction Stop
        $m=($z | ForEach-Object { ($_.CurrentTemperature/10)-273.15 } | Measure-Object -Maximum).Maximum
        if($m -gt 0 -and $m -lt 150){ return [math]::Round($m,1) }
    }catch{}
    return $null
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
$Cfg=@{ Cpu=150; RamPct=75; RamLoops=2; DiscoGB=2.0; Comb=90; Nome='COMPLETO' }

function T-Info {
    Set-Screen 'Identificação do equipamento' 'Lendo fabricante, modelo, numero de série, BIOS, CPU, memória, discos, tela e Windows...'
    $cs=Get-CimInstance Win32_ComputerSystem; $bios=Get-CimInstance Win32_BIOS
    $cpu=Get-CimInstance Win32_Processor | Select-Object -First 1
    $os=Get-CimInstance Win32_OperatingSystem
    $mem=@(Get-CimInstance Win32_PhysicalMemory)
    $ramGB=[math]::Round($cs.TotalPhysicalMemory/1GB,1)
    $memTxt= if($mem.Count){ ($mem | ForEach-Object { "{0}GB {1}MHz {2}" -f [math]::Round($_.Capacity/1GB),$_.Speed,$_.Manufacturer }) -join ' + ' } else { 'n/d' }
    $disks=@(Get-PhysicalDisk -ErrorAction SilentlyContinue | ForEach-Object { "{0} ({1}, {2}GB, {3})" -f $_.FriendlyName,$_.MediaType,[math]::Round($_.Size/1GB),$_.BusType }) -join ' | '
    $gpus=@(Get-CimInstance Win32_VideoController | ForEach-Object { $_.Name }) -join ' | '
    $scr=[Windows.Forms.Screen]::PrimaryScreen.Bounds
    $lic='n/d'
    try{ $p=Get-CimInstance SoftwareLicensingProduct | Where-Object { $_.PartialProductKey -and $_.Name -like 'Windows*' } | Select-Object -First 1; $lic= if($p.LicenseStatus -eq 1){'Ativado'}else{'NÃO ativado'} }catch{}
    $tpm='n/d'; try{ $t=Get-Tpm -ErrorAction Stop; $tpm= if($t.TpmPresent){'Presente'}else{'Ausente'} }catch{}
    $sb='n/d'; try{ $sb= if(Confirm-SecureBootUEFI -ErrorAction Stop){'Ativo'}else{'Desativado'} }catch{ $sb='Indisponível/BIOS legado' }
    $serial=([string]$bios.SerialNumber).Trim(); if(-not $serial){ $serial='SEM-SERIAL' }
    $script:Info['Fabricante']=$cs.Manufacturer; $script:Info['Modelo']=$cs.Model; $script:Info['Número de série']=$serial
    $script:Info['BIOS']=("{0} ({1})" -f $bios.SMBIOSBIOSVersion,$(if($bios.ReleaseDate){$bios.ReleaseDate.ToString('yyyy-MM-dd')}else{'n/d'}))
    $script:Info['Processador']=("{0} - {1} nucleos / {2} threads" -f ([string]$cpu.Name).Trim(),$cpu.NumberOfCores,$cpu.NumberOfLogicalProcessors)
    $script:Info['Memória RAM']=("{0} GB  [{1}]" -f $ramGB,$memTxt)
    $script:Info['Discos']=$disks; $script:Info['Video']=$gpus
    $script:Info['Tela principal']=("{0}x{1}" -f $scr.Width,$scr.Height)
    $script:Info['Windows']=("{0} (build {1}) - {2}" -f $os.Caption,$os.BuildNumber,$lic)
    $script:Info['TPM / Secure Boot']="$tpm / $sb"
    $ui_Sub.Text=("{0} {1}  |  S/N {2}" -f $cs.Manufacturer,$cs.Model,$serial)
    $script:Serial=$serial
    Live (($script:Info.GetEnumerator() | ForEach-Object { "{0,-18}: {1}" -f $_.Key,$_.Value }) -join "`r`n") 15
    Set-T 'info' 'OK' ("{0} {1} | S/N {2}" -f $cs.Manufacturer,$cs.Model,$serial)
}

function T-Cpu {
    $n=[Environment]::ProcessorCount; $secs=[int]$Cfg.Cpu
    Set-Screen 'Estresse de CPU' ("100% de carga em $n threads por $secs s. Cada thread repete o mesmo cálculo e compara o resultado: qualquer divergencia indica CPU/memória instavel.")
    $s=New-Object CpuStress; $s.Start($n)
    $sw=[Diagnostics.Stopwatch]::StartNew(); $tmax=0; $tnext=0; $load=0
    while($sw.Elapsed.TotalSeconds -lt $secs){
        UI-Pump; Start-Sleep -Milliseconds 200
        $ui_Barra.Value=[math]::Min(100,$sw.Elapsed.TotalSeconds*100/$secs)
        if($sw.Elapsed.TotalSeconds -ge $tnext){
            $tnext+=3; $t=Get-CpuTemp; if($t -and $t -gt $tmax){ $tmax=$t }
            try{ $load=(Get-CimInstance Win32_Processor | Measure-Object LoadPercentage -Average).Average }catch{}
            $clk=''; try{ $pr=Get-CimInstance Win32_Processor | Select-Object -First 1; $clk=("{0} MHz (máx {1})" -f $pr.CurrentClockSpeed,$pr.MaxClockSpeed) }catch{}
            Live ("Tempo: {0:N0}/{1} s`r`nCarga CPU: {2}%`r`nTemperatura da CPU: {3}   (máxima até agora: {6})`r`nClock: {7}`r`nCiclos de verificação: {4}   Erros: {5}" -f $sw.Elapsed.TotalSeconds,$secs,$load,$(if($t){"$t C"}else{'indisponível'}),$s.Ops,$s.Errors,$(if($tmax){"$tmax C"}else{'n/d'}),$clk)
        }
    }
    $s.Stop=$true; $s.Join()
    $d=("{0} threads, {1} ciclos, {2} erros, temp max {3}" -f $n,$s.Ops,$s.Errors,$(if($tmax){"$tmax C"}else{'n/d'}))
    if($s.Errors -gt 0){ Set-T 'cpu' 'FALHA' "Erros de cálculo detectados: $d" }
    elseif($tmax -ge 95){ Set-T 'cpu' 'FALHA' "Superaquecimento: $d" }
    elseif($tmax -ge 85){ Set-T 'cpu' 'ALERTA' "Temperatura alta: $d" }
    else { Set-T 'cpu' 'OK' $d }
}

function T-Ram {
    $os=Get-CimInstance Win32_OperatingSystem
    $freeB=[long]$os.FreePhysicalMemory*1024
    $target=[long]([math]::Max(256MB,($freeB*$Cfg.RamPct/100)))
    Set-Screen 'Teste de memória RAM' ("Gravando e conferindo padrões (AA/55/00/FF, endereçamento e pseudoaleatório) em cerca de {0:N1} GB livres, {1} passada(s)." -f ($target/1GB),$Cfg.RamLoops)
    $r=New-Object RamTest; $r.RunAsync($target,[int]$Cfg.RamLoops)
    while(-not $r.Done){ UI-Pump; Start-Sleep -Milliseconds 200; $ui_Barra.Value=$r.Pct; Live ("Progresso: {0}%`r`nMemoria sob teste: {1:N1} GB`r`nErros: {2}" -f $r.Pct,($r.Tested/1GB),$r.Errors) }
    $total=[math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory/1GB,1)
    $cobertura=[math]::Round(($r.Tested/1GB)*100/$total,0)
    $d=("{0:N1} GB testados ({1}% do total de {2} GB), {3} erros" -f ($r.Tested/1GB),$cobertura,$total,$r.Errors)
    if($r.Errors -gt 0){ Set-T 'ram' 'FALHA' "Memória com erros: $d" } else { Set-T 'ram' 'OK' $d }
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
    Set-Screen 'Estresse combinado (CPU + RAM + disco ao mesmo tempo)' ("Por $secs s: todos os nucleos, ~50% da RAM livre e escrita continua em disco simultaneamente. Simula o pior caso de energia/temperatura.")
    $os=Get-CimInstance Win32_OperatingSystem; $target=[long](([long]$os.FreePhysicalMemory*1024)*0.5)
    $cpu=New-Object CpuStress; $ram=New-Object RamTest; $dsk=New-Object DiskTest
    $cpu.Start($n); $ram.RunAsync($target,1000); $dsk.RunAsync("$Base\stress.bin",512MB,$true)
    $sw=[Diagnostics.Stopwatch]::StartNew(); $tmax=0; $tnext=0; $bat0=$null
    while($sw.Elapsed.TotalSeconds -lt $secs){
        UI-Pump; Start-Sleep -Milliseconds 200
        $ui_Barra.Value=[math]::Min(100,$sw.Elapsed.TotalSeconds*100/$secs)
        if($sw.Elapsed.TotalSeconds -ge $tnext){
            $tnext+=3; $t=Get-CpuTemp; if($t -and $t -gt $tmax){ $tmax=$t }
            Live ("Tempo: {0:N0}/{1} s`r`nTemp: {2}`r`nCPU erros: {3}   RAM erros: {4}   Disco erros: {5}`r`nDisco: escrita {6:N0} MB/s" -f $sw.Elapsed.TotalSeconds,$secs,$(if($t){"$t C"}else{'n/d'}),$cpu.Errors,$ram.Errors,$dsk.Errors,$dsk.WriteMBs)
        }
    }
    $cpu.Stop=$true; $ram.Cancel=$true; $dsk.Cancel=$true; $cpu.Join()
    $w=[Diagnostics.Stopwatch]::StartNew(); while((-not $ram.Done -or -not $dsk.Done) -and $w.Elapsed.TotalSeconds -lt 40){ UI-Pump; Start-Sleep -Milliseconds 100 }
    Remove-Item "$Base\stress.bin" -ErrorAction SilentlyContinue
    $err=$cpu.Errors+$ram.Errors+$dsk.Errors
    $d=("{0}s | erros CPU/RAM/Disco: {1}/{2}/{3} | temp max {4} | escrita {5:N0} MB/s" -f $secs,$cpu.Errors,$ram.Errors,$dsk.Errors,$(if($tmax){"$tmax C"}else{'n/d'}),$dsk.WriteMBs)
    if($err -gt 0 -or $dsk.Err){ Set-T 'comb' 'FALHA' "Instabilidade sob carga: $d $($dsk.Err)" }
    elseif($tmax -ge 95){ Set-T 'comb' 'FALHA' "Superaquecimento: $d" }
    elseif($tmax -ge 85){ Set-T 'comb' 'ALERTA' "Temperatura alta: $d" }
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
    Set-Screen 'Alto-falantes e microfone' 'Automático: o volume vai ao máximo e o notebook toca um tom em cada lado enquanto o microfone escuta. Fique em silêncio. Só pergunta se algo não for detectado.'
    $script:MciLog=@()
    try{ [MobNative]::VolumeMax() }catch{ Log ("VolumeMax: "+$_.Exception.Message) }
    Wait-UI 600
    Live 'Medindo ruído ambiente...' 20
    $f0="$Base\rec_amb.wav"; $amb=0.0; $recOK=Start-Rec
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
    if($loopOK){ $micTxt='detectado automaticamente: o microfone captou o som dos dois alto-falantes' }
    else {
        Log ("Áudio automático inconclusivo: "+($det -join ' | ')+' '+($script:MciLog -join ' | '))
        # confirmação manual somente do que não foi detectado
        foreach($par in @(@(1,'ESQUERDO'),@(2,'DIREITO'))){
            if($res[$par[1]]){ continue }
            do{
                Live ("Tocando som somente no lado {0}..." -f $par[1]) 22; try{ Play-Tone $par[0] ("m"+$par[1]) 1.6 $false }catch{ Log ("Play-Tone: "+$_.Exception.Message) }
                $r=Wait-Click @(("Ouvi no lado {0}" -f $par[1]),'Repetir som','Não ouvi')
            } while($r -eq 'Repetir som')
            $res[$par[1]]=($r -like 'Ouvi*')
        }
        $spkL=$res['ESQUERDO']; $spkR=$res['DIREITO']
        if($recOK){
            Live 'Teste do microfone: FALE ou bata palmas por 4 s depois de clicar...' 20
            [void](Wait-Click @('Iniciar gravação'))
            Live 'Gravando... fale agora!' 28
            if(Start-Rec){ Wait-UI 4000; Stop-Rec $f0; if(Test-Path $f0){ $b2=[WavTool]::Level($f0); $micOK=($b2[0] -gt 0.01 -or $b2[1] -gt 0.08); $micTxt=("RMS {0:N4} pico {1:N2}" -f $b2[0],$b2[1]) } }
        } else { $micOK=$false; $micTxt='não foi possível gravar: '+($script:MciLog -join ' | ') }
    }
    Remove-Item "$Base\*.wav" -ErrorAction SilentlyContinue
    $d=("Esquerdo: {0} | Direito: {1} | Microfone: {2} ({3})" -f $(if($spkL){'OK'}else{'FALHOU'}),$(if($spkR){'OK'}else{'FALHOU'}),$(if($micOK){'OK'}else{'FALHOU'}),$micTxt)
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
function Build-Report {
    $enc={ param($x) [System.Net.WebUtility]::HtmlEncode([string]$x) }
    $falhas=@($Tests | Where-Object Status -eq 'FALHA'); $alertas=@($Tests | Where-Object Status -eq 'ALERTA')
    $veredito= if($falhas.Count){'REPROVADO'}elseif($alertas.Count){'APROVADO COM RESSALVAS'}else{'APROVADO'}
    $corV= if($falhas.Count){'#d93636'}elseif($alertas.Count){'#d99a1f'}else{'#1f9d55'}
    $cores=@{OK='#1f9d55';ALERTA='#d99a1f';FALHA='#d93636';PULADO='#7c8794';PENDENTE='#7c8794';RODANDO='#4da3ff'}
    $inf=($script:Info.GetEnumerator() | ForEach-Object { "<tr><th>{0}</th><td>{1}</td></tr>" -f (& $enc $_.Key),(& $enc $_.Value) }) -join "`n"
    $lin=($Tests | ForEach-Object { "<tr><td>{0}</td><td><b style='color:{1}'>{2}</b></td><td>{3}</td><td>{4}s</td></tr>" -f (& $enc $_.Nome),$cores[$_.Status],$_.Status,(& $enc $_.Detalhe),$_.Seg }) -join "`n"
    $html=@"
<!doctype html><html lang="pt-BR"><head><meta charset="utf-8"><title>MOB-CHECK PC - $(& $enc $script:Serial)</title>
<style>body{font-family:Segoe UI,Arial,sans-serif;margin:30px;color:#1b2430}h1{margin:0}h1 span{color:#2f7bd6}
.v{display:inline-block;padding:10px 22px;border-radius:8px;color:#fff;font-size:22px;font-weight:700;margin:14px 0;background:$corV}
table{border-collapse:collapse;width:100%;margin:12px 0 26px}th,td{border:1px solid #d5dbe3;padding:7px 10px;text-align:left;font-size:14px;vertical-align:top}
th{background:#f1f4f8;width:200px}.t th{width:auto}</style></head><body>
<h1><span>MOB</span>-CHECK PC</h1><div>MOBIT SOLUÇÕES - relatório de teste de notebook - $(Get-Date -Format 'dd/MM/yyyy HH:mm')</div>
<div class="v">$veredito</div>
<div>$($falhas.Count) falha(s), $($alertas.Count) alerta(s), $(@($Tests | Where-Object Status -eq 'OK').Count) teste(s) OK</div>
<h2>Equipamento</h2><table>$inf</table>
<h2>Resultados</h2><table class="t"><tr><th>Teste</th><th>Resultado</th><th>Detalhes</th><th>Duração</th></tr>$lin</table>
</body></html>
"@
    $nome="MOB-CHECK_{0}_{1}" -f ($script:Serial -replace '[^A-Za-z0-9\-]','_'),(Get-Date -Format 'yyyyMMdd-HHmm')
    $script:ReportFile="$RelDir\$nome.html"
    Set-Content -Path $script:ReportFile -Value $html -Encoding UTF8
    Copy-Item $script:ReportFile "$RelDir\ultimo-relatorio.html" -Force
    $Tests | Select-Object Id,Nome,Status,Detalhe,Seg | ConvertTo-Json | Set-Content "$RelDir\$nome.json" -Encoding UTF8
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
if($modo -eq 'R'){ $Cfg=@{ Cpu=20; RamPct=50; RamLoops=1; DiscoGB=0.5; Comb=20; Nome='RAPIDO' } }
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
$ver=Build-Report
New-Item -ItemType File -Force -Path "$Base\done.flag" | Out-Null
Cleanup
$corFinal= if($ver -eq 'REPROVADO'){'#FF5C5C'}elseif($ver -like '*RESSALVAS'){'#FFC247'}else{'#3DDC84'}
Set-Screen 'Teste concluído' ("Relatório salvo em: "+$script:ReportFile)
$tb=New-Object Windows.Controls.TextBlock; $tb.Text=$ver; $tb.FontSize=54; $tb.FontWeight='Black'; $tb.Foreground=(Br $corFinal); $tb.HorizontalAlignment='Center'; $tb.VerticalAlignment='Center'
$ui_Painel.Content=$tb; $ui_Barra.Value=100
Log "Veredito: $ver"
while($true){
    $r=Wait-Click @('Abrir relatório','Copiar para pendrive','Refazer testes','Fechar','Apagar Wi-Fi MOB e fechar')
    switch($r){
        'Abrir relatório' { Start-Process $script:ReportFile }
        'Copiar para pendrive' {
            $u=@(Get-UsbDrives); if($u.Count){ foreach($d in $u){ New-Item -ItemType Directory -Force -Path "$d\MOB-RELATORIOS" | Out-Null; Copy-Item $script:ReportFile "$d\MOB-RELATORIOS\" -Force }; Log ("Copiado para: "+($u -join ', ')) } else { Log 'Nenhum pendrive encontrado' }
        }
        'Refazer testes' { Remove-Item "$Base\done.flag" -ErrorAction SilentlyContinue; try{ $script:Mutex.ReleaseMutex() }catch{}; Start-Process powershell -ArgumentList "-NoProfile -ExecutionPolicy Bypass -STA -File `"$PSCommandPath`"$extra"; $Win.Close() }
        'Fechar' { $Win.Close() }
        'Apagar Wi-Fi MOB e fechar' {
            # remove as redes/senhas da MOB deste notebook (use antes de entregar ao cliente)
            $cfg=Get-ItemProperty -Path 'HKLM:\SOFTWARE\MOB' -ErrorAction SilentlyContinue
            foreach($s in @(@($cfg.WifiSSID,$cfg.WifiSSID2,$cfg.WifiSSID3) | Where-Object { $_ })){ $o=netsh wlan delete profile name="$s"; Log ("Removido perfil Wi-Fi {0}: {1}" -f $s,($o -join ' ')) }
            foreach($n in 'WifiSSID','WifiSenha','WifiAuth','WifiSSID2','WifiSenha2','WifiAuth2','WifiSSID3','WifiSenha3','WifiAuth3'){ Remove-ItemProperty -Path 'HKLM:\SOFTWARE\MOB' -Name $n -ErrorAction SilentlyContinue }
            Wait-UI 1500; $Win.Close()
        }
    }
}
