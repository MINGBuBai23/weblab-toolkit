using System;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Text;

// WebLab / USTCORi.SimExp 实验数据包工具
//   LabDecrypt dec   <ExamConfig.bin> [out.xml]     解密试卷 / 提交包
//   LabDecrypt enc   <ExamConfig.xml> [out.bin]     加密
//   LabDecrypt key   <serialnumber>                 生成服务端签名 Sec.GenerateKey
//   LabDecrypt cmd   "<Main.exe 命令行参数>"          还原实验启动参数（10 段）
class LabDecrypt
{
    const string Token = "haohaoxuexi,tiantianxiangshang.";
    const string DllName = "USTCORi.SimExp.Instruments.Component.dll";

    static string FindComponent()
    {
        var cands = new System.Collections.Generic.List<string>();
        string here = AppDomain.CurrentDomain.BaseDirectory;
        cands.Add(Path.Combine(here, DllName));
        cands.Add(Path.Combine(Directory.GetCurrentDirectory(), DllName));

        // 没随包携带时，从实验客户端的解包目录里找（%TEMP%\lab\<编号>\ 或 %TEMP%\lab\）
        string tmp = Environment.GetEnvironmentVariable("TEMP");
        if (tmp != null)
        {
            try
            {
                var dirs = Directory.GetDirectories(Path.Combine(tmp, "lab"))
                                    .Select(d => new DirectoryInfo(d))
                                    .OrderByDescending(d => d.LastWriteTime);
                foreach (var d in dirs) cands.Add(Path.Combine(d.FullName, DllName));
            }
            catch { }
            cands.Add(Path.Combine(tmp, "lab", DllName));
        }

        foreach (string c in cands)
            if (File.Exists(c)) return c;

        Console.WriteLine("找不到 " + DllName);
        Console.WriteLine("任选一种方式解决：");
        Console.WriteLine("  1) 把客户端里的该文件复制到本目录；");
        Console.WriteLine("  2) 先启动一次任意实验（客户端会解包到 %TEMP%\\lab\\），再运行本工具。");
        return null;
    }

    static Assembly Comp()
    {
        string p = FindComponent();
        if (p == null) Environment.Exit(2);
        return Assembly.LoadFrom(p);
    }

    static object InvokeStatic(Assembly asm, string typeName, string method, Type argType, object arg)
    {
        Type t = null;
        foreach (Type x in asm.GetTypes())
            if (x.FullName == typeName || x.Name == typeName) { t = x; break; }
        if (t == null) throw new Exception("type not found: " + typeName);
        foreach (MethodInfo mi in t.GetMethods(BindingFlags.Public | BindingFlags.NonPublic | BindingFlags.Static))
        {
            ParameterInfo[] ps = mi.GetParameters();
            if (mi.Name == method && ps.Length == 1 && ps[0].ParameterType == argType)
                return mi.Invoke(null, new object[] { arg });
        }
        throw new Exception("method not found: " + method + "(" + argType.Name + ")");
    }

    static byte[] InvokeJson(Assembly asm, string method, byte[] bytes)
    {
        Type t = null;
        foreach (Type x in asm.GetTypes())
            if (x.Name == (method == "Read" ? "JsonReader" : "JsonWriter")) { t = x; break; }
        foreach (MethodInfo mi in t.GetMethods(BindingFlags.Public | BindingFlags.Static))
        {
            ParameterInfo[] ps = mi.GetParameters();
            if (mi.Name == method && ps.Length == 2 && ps[0].ParameterType == typeof(byte[]))
                return (byte[])mi.Invoke(null, new object[] { bytes, Token });
        }
        throw new Exception("method not found: " + method);
    }

    static void Main(string[] args)
    {
        if (args.Length < 2)
        {
            Console.WriteLine("usage:");
            Console.WriteLine("  LabDecrypt dec <ExamConfig.bin> [out.xml]");
            Console.WriteLine("  LabDecrypt enc <ExamConfig.xml> [out.bin]");
            Console.WriteLine("  LabDecrypt key <serialnumber>");
            Console.WriteLine("  LabDecrypt cmd \"<Main.exe 命令行参数>\"");
            return;
        }
        string mode = args[0];
        Assembly asm = Comp();

        if (mode == "key")
        {
            Console.WriteLine(InvokeStatic(asm, "Sec", "GenerateKey", typeof(string), args[1]));
            return;
        }

        if (mode == "cmd")
        {
            string raw = (string)InvokeStatic(asm, "XlsxFileReader", "Read", typeof(string), args[1]);
            if (raw == null) { Console.WriteLine("解密失败（参数不是 XlsxFileWriter.Write 的产物）"); return; }
            string[] f = raw.Split('|');
            string[] names = { "hWnd", "tag", "paper", "userid", "LabID", "LabName", "RecordID", "md5Key", "time", "ServerIP", "Language" };
            for (int i = 0; i < f.Length; i++)
            {
                string val;
                try { val = Encoding.UTF8.GetString(Convert.FromBase64String(f[i])); }
                catch { val = "<非base64>" + f[i]; }
                Console.WriteLine(string.Format("{0,-9} = {1}", i < names.Length ? names[i] : ("#" + i), val));
            }
            return;
        }

        string path = args[1];
        byte[] bytes = File.ReadAllBytes(path);
        if (mode == "dec")
        {
            byte[] outb = InvokeJson(asm, "Read", bytes);
            string dest = args.Length > 2 ? args[2] : path + ".xml";
            File.WriteAllText(dest, Encoding.UTF8.GetString(outb), new UTF8Encoding(false));
            Console.WriteLine("decrypted " + outb.Length + " bytes -> " + dest);
        }
        else
        {
            byte[] outb = InvokeJson(asm, "Write", bytes);
            string dest = args.Length > 2 ? args[2] : path + ".bin";
            File.WriteAllBytes(dest, outb);
            Console.WriteLine("encrypted " + outb.Length + " bytes -> " + dest);
        }
    }
}
