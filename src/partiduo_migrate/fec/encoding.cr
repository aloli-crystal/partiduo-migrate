# SPDX-License-Identifier: AGPL-3.0-or-later

module PartiduoMigrate
  module Fec
    # Encodages d'un FEC. L'arrêté admet l'ASCII et l'ISO 8859-15 ; les
    # logiciels produisent aussi de l'UTF-8 (avec ou sans BOM) et du
    # Windows-1252. Sans indication, l'outil reconnaît un BOM, puis de
    # l'UTF-8 valide, et lit sinon en ISO 8859-15.
    module Encoding
      UTF8_BOM    = Bytes[0xEF, 0xBB, 0xBF]
      UTF16LE_BOM = Bytes[0xFF, 0xFE]
      UTF16BE_BOM = Bytes[0xFE, 0xFF]

      ALIASES = {
        "utf8"         => "UTF-8",
        "utf-8"        => "UTF-8",
        "latin9"       => "ISO-8859-15",
        "iso-8859-15"  => "ISO-8859-15",
        "iso8859-15"   => "ISO-8859-15",
        "latin1"       => "ISO-8859-1",
        "iso-8859-1"   => "ISO-8859-1",
        "cp1252"       => "WINDOWS-1252",
        "windows-1252" => "WINDOWS-1252",
        "ascii"        => "ASCII",
        "utf-16"       => "UTF-16",
      }

      # Nom canonique d'un encodage demandé ; `Error` s'il est inconnu.
      def self.canonical(name : String) : String
        ALIASES[name.strip.downcase]? || raise Error.new("encodage inconnu : #{name}")
      end

      # Texte du fichier et encodage retenu.
      def self.decode(bytes : Bytes, forced : String? = nil) : {String, String}
        if forced
          name = canonical(forced)
          bytes = bytes[UTF8_BOM.size..] if name == "UTF-8" && bytes[0, 3]? == UTF8_BOM
          return {name == "UTF-8" ? utf8!(bytes) : convert(bytes, name), name}
        end
        return {utf8!(bytes[UTF8_BOM.size..]), "UTF-8"} if bytes[0, 3]? == UTF8_BOM
        return {convert(bytes, "UTF-16"), "UTF-16"} if bytes[0, 2]?.in?(UTF16LE_BOM, UTF16BE_BOM)
        text = String.new(bytes)
        return {text, text.ascii_only? ? "ASCII" : "UTF-8"} if text.valid_encoding?
        {convert(bytes, "ISO-8859-15"), "ISO-8859-15"}
      end

      # Texte écrit dans l'encodage demandé ; un caractère que l'encodage ne
      # représente pas est une erreur (jamais remplacé en silence).
      def self.encode(text : String, name : String) : Bytes
        name = canonical(name)
        return text.to_slice if name == "UTF-8"
        text.encode(name)
      rescue ex : ArgumentError
        raise Error.new("texte non représentable en #{name} : #{ex.message}")
      end

      private def self.utf8!(bytes : Bytes) : String
        text = String.new(bytes)
        raise Error.new("le fichier n'est pas en UTF-8 valide") unless text.valid_encoding?
        text
      end

      private def self.convert(bytes : Bytes, name : String) : String
        String.new(bytes, name)
      rescue ex : ArgumentError
        raise Error.new("lecture en #{name} impossible : #{ex.message}")
      end
    end
  end
end
