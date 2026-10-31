// Per-interface DNS API: no changes to the machine-wide DoH resolver list.
// https://learn.microsoft.com/windows/win32/api/netioapi/ns-netioapi-dns_interface_settings3
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Runtime.InteropServices;

namespace ZapretDns {
    public sealed class DohProperty {
        public uint Index;
        public string Template;
        public ulong Flags;
    }
    public sealed class FamilySettings {
        public bool IPv6;
        public uint Version;
        public string NameServer;
        public string ProfileNameServer;
        public DohProperty[] Properties;
        public DohProperty[] ProfileProperties;
    }
    public static class Native {
        [StructLayout(LayoutKind.Sequential)]
        private struct Settings {
            public uint Version;
            public ulong Flags;
            public IntPtr Domain, NameServer, SearchList;
            public uint RegistrationEnabled, RegisterAdapterName, EnableLLMNR, QueryAdapterName;
            public IntPtr ProfileNameServer;
            public uint DisableUnconstrainedQueries;
            public IntPtr SupplementalSearchList;
            public uint PropertyCount;
            public IntPtr Properties;
            public uint ProfilePropertyCount;
            public IntPtr ProfileProperties;
        }
        [StructLayout(LayoutKind.Sequential)]
        private struct Property {
            public uint Version, ServerIndex, Type;
            public IntPtr Value;
        }
        [StructLayout(LayoutKind.Sequential)]
        private struct DohSettings {
            public IntPtr Template;
            public ulong Flags;
        }
        [DllImport("iphlpapi.dll", ExactSpelling = true)]
        private static extern uint GetInterfaceDnsSettings(Guid adapter, ref Settings settings);
        [DllImport("iphlpapi.dll", ExactSpelling = true)]
        private static extern uint SetInterfaceDnsSettings(Guid adapter, ref Settings settings);
        [DllImport("iphlpapi.dll", ExactSpelling = true)]
        private static extern void FreeInterfaceDnsSettings(ref Settings settings);

        private static DohProperty[] ReadProperties(IntPtr pointer, uint count) {
            var result = new List<DohProperty>();
            if (count > 128 || (count != 0 && pointer == IntPtr.Zero))
                throw new InvalidOperationException("Invalid DNS property list.");
            for (int i = 0; i < count; i++) {
                var entry = (Property)Marshal.PtrToStructure(IntPtr.Add(pointer, i * Marshal.SizeOf(typeof(Property))), typeof(Property));
                if (entry.Version != 1 || entry.Type != 1 || entry.Value == IntPtr.Zero)
                    throw new NotSupportedException("This adapter has DNS properties that cannot be safely backed up.");
                var doh = (DohSettings)Marshal.PtrToStructure(entry.Value, typeof(DohSettings));
                result.Add(new DohProperty { Index = entry.ServerIndex, Template = Marshal.PtrToStringUni(doh.Template), Flags = doh.Flags });
            }
            return result.ToArray();
        }
        public static FamilySettings Read(Guid adapter, bool ipv6, uint version) {
            var settings = new Settings { Version = version, Flags = ipv6 ? 1UL : 0UL };
            uint error = GetInterfaceDnsSettings(adapter, ref settings);
            if (error != 0) throw new Win32Exception((int)error, "Cannot read adapter DNS settings (" + error + ").");
            try {
                return new FamilySettings {
                    IPv6 = ipv6, Version = version,
                    NameServer = Marshal.PtrToStringUni(settings.NameServer),
                    ProfileNameServer = Marshal.PtrToStringUni(settings.ProfileNameServer),
                    Properties = ReadProperties(settings.Properties, settings.PropertyCount),
                    ProfileProperties = ReadProperties(settings.ProfileProperties, settings.ProfilePropertyCount)
                };
            } finally { FreeInterfaceDnsSettings(ref settings); }
        }
        private static IntPtr AllocateString(string value, List<IntPtr> memory) {
            IntPtr pointer = Marshal.StringToHGlobalUni(value ?? "");
            memory.Add(pointer);
            return pointer;
        }
        private static IntPtr WriteProperties(DohProperty[] values, List<IntPtr> memory) {
            if (values == null || values.Length == 0) return IntPtr.Zero;
            int size = Marshal.SizeOf(typeof(Property));
            IntPtr array = Marshal.AllocHGlobal(checked(size * values.Length));
            memory.Add(array);
            for (int i = 0; i < values.Length; i++) {
                var value = values[i];
                var doh = new DohSettings { Flags = value.Flags,
                    Template = String.IsNullOrEmpty(value.Template) ? IntPtr.Zero : AllocateString(value.Template, memory) };
                IntPtr pointer = Marshal.AllocHGlobal(Marshal.SizeOf(typeof(DohSettings)));
                memory.Add(pointer);
                Marshal.StructureToPtr(doh, pointer, false);
                var entry = new Property { Version = 1, ServerIndex = value.Index, Type = 1, Value = pointer };
                Marshal.StructureToPtr(entry, IntPtr.Add(array, i * size), false);
            }
            return array;
        }
        public static void Write(Guid adapter, FamilySettings value) {
            var memory = new List<IntPtr>();
            try {
                // Set only DNS addresses/properties; leave IP, suffixes and registration alone.
                var settings = new Settings { Version = value.Version, Flags = (value.IPv6 ? 1UL : 0UL) | 2UL | 0x200UL,
                    NameServer = AllocateString(value.NameServer, memory),
                    ProfileNameServer = AllocateString(value.ProfileNameServer, memory) };
                if (value.Version == 3) {
                    if (!String.IsNullOrWhiteSpace(value.NameServer)) {
                        settings.Flags |= 0x1000UL;
                        settings.PropertyCount = (uint)(value.Properties == null ? 0 : value.Properties.Length);
                        settings.Properties = WriteProperties(value.Properties, memory);
                    }
                    if (!String.IsNullOrWhiteSpace(value.ProfileNameServer)) {
                        settings.Flags |= 0x2000UL;
                        settings.ProfilePropertyCount = (uint)(value.ProfileProperties == null ? 0 : value.ProfileProperties.Length);
                        settings.ProfileProperties = WriteProperties(value.ProfileProperties, memory);
                    }
                }
                uint error = SetInterfaceDnsSettings(adapter, ref settings);
                if (error != 0) throw new Win32Exception((int)error, "Cannot apply adapter DNS settings (" + error + ").");
            } finally { foreach (IntPtr pointer in memory) Marshal.FreeHGlobal(pointer); }
        }
    }
}
