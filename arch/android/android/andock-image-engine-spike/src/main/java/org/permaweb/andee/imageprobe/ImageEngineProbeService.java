package org.permaweb.andee.imageprobe;

import android.app.Service;
import android.content.Intent;
import android.os.IBinder;
import android.os.ParcelFileDescriptor;
import android.os.Process;

public final class ImageEngineProbeService extends Service {
    private final IImageEngineProbe.Stub binder = new IImageEngineProbe.Stub() {
        @Override
        public String initialize(ParcelFileDescriptor image) {
            try (image) {
                return NativeProbe.initialize(image.getFd());
            } catch (Exception error) {
                return "result=failed\nservice-error=" + error + "\n";
            }
        }

        @Override
        public String verify(ParcelFileDescriptor image) {
            try (image) {
                return NativeProbe.verify(image.getFd());
            } catch (Exception error) {
                return "result=failed\nservice-error=" + error + "\n";
            }
        }

        @Override
        public void crashAfterMutation(ParcelFileDescriptor image) {
            NativeProbe.crashAfterMutation(image.getFd());
        }

        @Override
        public String rejectMalformed(ParcelFileDescriptor image, int kind) {
            try (image) {
                return NativeProbe.rejectMalformed(image.getFd(), kind);
            } catch (Exception error) {
                return "result=failed\nservice-error=" + error + "\n";
            }
        }

        @Override
        public int isolatedUid() {
            return Process.myUid();
        }

        @Override
        public int isolatedPid() {
            return Process.myPid();
        }
    };

    @Override
    public IBinder onBind(Intent intent) {
        return binder;
    }
}
