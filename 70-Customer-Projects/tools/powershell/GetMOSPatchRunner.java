// =============================================================================
// File     : GetMOSPatchRunner.java
// Purpose  : Start getMOSPatch.jar with the My Oracle Support user / password
//            WITHOUT putting them on an OS command line.
//            getMOSPatch reads the credentials only from System.console()
//            (null without a terminal - e.g. when started from PowerShell with
//            redirected streams) or from its arguments MOSUser= / MOSPass=.
//            This runner reads user and password from stdin (two lines) and
//            hands them to getMOSPatch.main() inside the same JVM - the
//            arguments of the JVM process (visible in Win32_Process /
//            ps) contain neither of them.
// Call     : java -cp getMOSPatch.jar GetMOSPatchRunner.java patch=<nr> [args]
//            (single-file source launch - Java 11 or newer; stdin: user, password)
//            java GetMOSPatchRunner.java --zipcheck <zip> [<zip> ...]
//            reads every entry completely (ZipInputStream checks the CRC of
//            each entry - like "unzip -t"); prints "OK <zip>" or
//            "BAD <zip> <reason>", exit 0 = all OK, 1 = at least one BAD
// Used by  : mos_patch_download.ps1
// Author   : Gunther Pipperr | https://pipperr.de
// License  : Apache 2.0
// =============================================================================
import java.io.BufferedInputStream;
import java.io.BufferedReader;
import java.io.FileInputStream;
import java.io.InputStreamReader;
import java.lang.reflect.Method;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.List;
import java.util.zip.ZipEntry;
import java.util.zip.ZipInputStream;

public class GetMOSPatchRunner {
    public static void main(String[] args) throws Exception {
        if (args.length > 0 && args[0].equals("--zipcheck")) {
            int bad = 0;
            byte[] buf = new byte[1 << 16];
            for (int i = 1; i < args.length; i++) {
                int n = 0;
                try (ZipInputStream z = new ZipInputStream(new BufferedInputStream(new FileInputStream(args[i])))) {
                    ZipEntry e;
                    while ((e = z.getNextEntry()) != null) {
                        while (z.read(buf) >= 0) { /* read to the end: CRC is checked */ }
                        n++;
                    }
                    if (n == 0) throw new java.io.IOException("no entries");
                    System.out.println("OK " + args[i] + " (" + n + " entries)");
                } catch (Exception ex) {
                    bad++;
                    System.out.println("BAD " + args[i] + " " + ex);
                }
            }
            System.exit(bad == 0 ? 0 : 1);
        }
        BufferedReader in = new BufferedReader(new InputStreamReader(System.in, StandardCharsets.UTF_8));
        String user = in.readLine();
        String pass = in.readLine();
        if (user == null || user.isEmpty() || pass == null || pass.isEmpty()) {
            System.err.println("GetMOSPatchRunner: expected MOS user and password on stdin (two lines)");
            System.exit(2);
        }
        List<String> all = new ArrayList<>();
        for (String a : args) {
            // never accept credentials from the command line
            if (a.startsWith("MOSUser=") || a.startsWith("MOSPass=")) continue;
            all.add(a);
        }
        all.add("MOSUser=" + user);
        all.add("MOSPass=" + pass);
        pass = null;
        // getMOSPatch is in the unnamed package of getMOSPatch.jar
        Class<?> c = Class.forName("getMOSPatch");
        Method m = c.getMethod("main", String[].class);
        m.invoke(null, (Object) all.toArray(new String[0]));
    }
}
