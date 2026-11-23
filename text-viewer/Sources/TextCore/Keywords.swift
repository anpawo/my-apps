/// A language's reserved words, split the way VS Code's TextMate grammars scope them, so each
/// group takes the color the theme gives that scope: `control` is keyword.control, `keyword` is
/// storage.type and keyword.other, `modifier` is storage.modifier and the word operators,
/// `literal` is constant.language, `language` is variable.language (self, this).
struct Words {
    var control = ""
    var keyword = ""
    var modifier = ""
    var literal = ""
    var language = ""
}

enum Keywords {
    static let swift = Words(
        control: """
        await break case catch continue default defer do else fallthrough for guard if import in \
        repeat return switch throw try where while yield
        """,
        keyword: """
        actor associatedtype class deinit didSet enum extension fileprivate func get init internal let \
        open operator package private protocol public set some any struct subscript typealias var willSet
        """,
        modifier: """
        async convenience dynamic final indirect inout lazy mutating nonisolated nonmutating optional \
        override required rethrows static throws unowned weak
        """,
        literal: "true false nil",
        language: "self Self super")

    static let python = Words(
        control: """
        assert async await break case continue del elif else except finally for from if import match \
        pass raise return try while with yield as
        """,
        keyword: "class def lambda",
        modifier: "global nonlocal",
        literal: "True False None",
        language: "self cls")

    static let javascript = Words(
        control: """
        as await break case catch continue default do else export finally for from if import return \
        switch throw try while with yield
        """,
        keyword: "class const constructor debugger enum function get interface let module namespace set type var",
        modifier: """
        abstract async declare delete extends implements in instanceof keyof new of override private \
        protected public readonly static typeof void
        """,
        literal: "true false null undefined NaN Infinity",
        language: "this super")

    static let c = Words(
        control: "break case catch continue default delete do else for goto if new return switch throw try using while",
        keyword: """
        auto bool BOOL char class double enum float friend id instancetype int long namespace operator \
        short signed struct template typedef typename union unsigned void
        """,
        modifier: """
        alignas alignof const constexpr explicit extern inline mutable noexcept private protected public \
        register sizeof static virtual volatile
        """,
        literal: "true false nullptr NULL YES NO nil",
        language: "this self super")

    static let rust = Words(
        control: "await break continue else for if in loop match return while yield",
        keyword: "const crate enum extern fn impl let mod pub static struct trait type use where",
        modifier: "async dyn move mut ref unsafe",
        literal: "true false",
        language: "self Self super")

    static let go = Words(
        control: "break case continue default defer else fallthrough for go goto if range return select switch",
        keyword: "chan const func import interface map package struct type var",
        literal: "true false nil iota")

    static let java = Words(
        control: "break case catch continue default do else finally for if new return switch throw try when while",
        keyword: """
        boolean byte char class double enum float fun import int interface long object package short \
        typealias val var void
        """,
        modifier: """
        abstract as companion const data extends final implements in inline is lateinit native open \
        override private protected public sealed static suspend synchronized throws transient volatile
        """,
        literal: "true false null",
        language: "this super")

    static let shell = Words(
        control: "break case continue do done elif else esac fi for if in return select then until while",
        keyword: "function",
        modifier: "declare export local readonly typeset unset")

    static let ruby = Words(
        control: """
        alias begin break case class def do else elsif end ensure for if in module next redo rescue \
        retry return super then undef unless until when while yield
        """,
        keyword: "attr_accessor attr_reader attr_writer extend include private protected public require require_relative",
        literal: "true false nil",
        language: "self")

    static let sql = """
    add all alter and as asc between by case check column constraint create database default delete desc \
    distinct drop else end exists foreign from group having in index inner insert into is join key left \
    like limit not offset on or order outer primary references right select set table then union \
    unique update values view when where with
    """

    static let lua = Words(
        control: "break do else elseif end for function goto if in repeat return then until while",
        keyword: "local",
        literal: "nil true false",
        language: "self")
}
