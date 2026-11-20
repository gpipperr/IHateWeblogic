// =============================================================================
// Script   : crop_png.java
// Purpose  : Cut a rectangle out of a PNG (screenshots -> small examples in the
//            docs). Needs only a JDK 11+ (single-file source launch) - no
//            ImageMagick / PIL on the FMW hosts (EPEL / pip are not allowed).
// Call     : java tools/crop_png.java IN.png OUT.png X Y WIDTH HEIGHT
//            e.g. java tools/crop_png.java page.png head.png 0 0 1360 305
//            Width / height are cut at the image border; prints OUT + size.
// Author   : Gunther Pipperr | https://pipperr.de
// License  : Apache 2.0
// =============================================================================
import javax.imageio.ImageIO;
import java.awt.image.BufferedImage;
import java.io.File;

public class crop_png {
    public static void main(String[] a) throws Exception {
        if (a.length != 6) {
            System.err.println("usage: java crop_png.java IN.png OUT.png X Y WIDTH HEIGHT");
            System.exit(2);
        }
        BufferedImage img = ImageIO.read(new File(a[0]));
        if (img == null) {
            System.err.println("not an image: " + a[0]);
            System.exit(1);
        }
        int x = Integer.parseInt(a[2]), y = Integer.parseInt(a[3]);
        int w = Math.min(Integer.parseInt(a[4]), img.getWidth() - x);
        int h = Math.min(Integer.parseInt(a[5]), img.getHeight() - y);
        if (x < 0 || y < 0 || w <= 0 || h <= 0) {
            System.err.println("rectangle outside the image (" + img.getWidth() + "x" + img.getHeight() + ")");
            System.exit(1);
        }
        ImageIO.write(img.getSubimage(x, y, w, h), "png", new File(a[1]));
        System.out.println(a[1] + " " + w + "x" + h);
    }
}
