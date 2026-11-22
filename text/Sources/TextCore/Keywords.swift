enum Keywords {
    static let swift = """
    actor any as associatedtype async await break case catch class continue default defer deinit do else \
    enum extension fallthrough false fileprivate final for func guard if import in indirect init inout \
    internal is lazy let mutating nil nonisolated nonmutating open operator override private protocol \
    public repeat rethrows return self Self some static struct subscript super switch throw throws true \
    try typealias var weak where while
    """
    static let python = """
    and as assert async await break case class continue def del elif else except False finally for from \
    global if import in is lambda match None nonlocal not or pass raise return self True try while with yield
    """
    static let javascript = """
    abstract as async await break case catch class const constructor continue debugger declare default \
    delete do else enum export extends false finally for from function get if implements import in \
    instanceof interface keyof let namespace new null of private protected public readonly return set \
    static super switch this throw true try type typeof undefined var void while with yield
    """
    static let c = """
    alignas alignof and auto bool break case catch char class const constexpr continue default delete do \
    double else enum explicit extern false float for friend goto if inline int long mutable namespace new \
    noexcept nullptr operator or private protected public register return short signed sizeof static \
    struct switch template this throw true try typedef typename union unsigned using virtual void \
    volatile while id self super nil YES NO BOOL instancetype
    """
    static let rust = """
    as async await break const continue crate dyn else enum extern false fn for if impl in let loop match \
    mod move mut pub ref return self Self static struct super trait true type unsafe use where while
    """
    static let go = """
    break case chan const continue default defer else fallthrough false for func go goto if import \
    interface iota map nil package range return select struct switch true type var
    """
    static let java = """
    abstract as boolean break byte case catch char class companion const continue data def default do \
    double else enum extends false final finally float for fun if implements import in int interface is \
    long new null object open override package private protected public return sealed short static super \
    switch this throw throws true try val var void when while
    """
    static let shell = """
    if then else elif fi case esac for while until do done in function return local export readonly \
    unset set source alias begin end not and or switch true false
    """
    static let ruby = """
    alias and begin break case class def defined do else elsif end ensure false for if in module next \
    nil not or redo require rescue retry return self super then true undef unless until when while yield
    """
    static let sql = """
    add all alter and as asc between by case check column constraint create database default delete desc \
    distinct drop else end exists foreign from group having in index inner insert into is join key left \
    like limit not null offset on or order outer primary references right select set table then union \
    unique update values view when where with
    """
    static let lua = """
    and break do else elseif end false for function goto if in local nil not or repeat return then true \
    until while
    """
}
